#!/bin/sh
DEFAULT_SETTINGS_FILE="$HOME/.config/sapfo/settings.json"
DEFAULT_CACHE_DIR="$HOME/.cache/sapfo"


fatal_error() {
    # $1 = message, $2 = exit code (optional)
    ERROR_PREFIX='error: '
    if test "$COLORMODE" = 'mono' ; then
        printf '%s%s\n' "$ERROR_PREFIX" "$1"
    else
        printf '%s%s%s%s\n' '[1;31m' "$ERROR_PREFIX" '[0m' "$1"
    fi
    exit "${2-1}"  # default to exit code 1
}


show_help() {
    SCRIPTNAME="$(basename "$0")"
    printf '%s' \
'Usage:
  '"$SCRIPTNAME"' [path-overrides] [options]
  '"$SCRIPTNAME"' -h | --help | (specific-help-topics)

Arguments are executed in order of appearance, except for path overrides
which have to be first. This will usually not affect anything, since the
actual filtering and sorting is done after all arguments have been
parsed, but options that affect output (eg. color modes and help)
and options that override the regular view mode (eg. edit)
might behave differently.

Running without any arguments shows the currently visible entries
(after active filtering and sorting has been applied).

Actions:
  -lt                     list all tags
  -e<NUM>                 edit the entry with index <NUM>

Sorting:
  -s                      print active sort key
  -sn, -sn-               sort on name (append - for reverse)
  -sc, -sc-               sort on wordcount (append - for reverse)
  -sm, -sm-               sort on last modified date (append - for reverse)

Filtering:
  -f                      print active filters
  -fn <TEXT>              show entries with <TEXT> in their title
  -fd <TEXT>              show entries with <TEXT> in their description
  -ft <TAGEXPR>           show entries matching the tag expression
  -fc <NUMEXPR>           show entries matching the wordcount expression
  -f0                     reset all filters
  -f[ndtc]0               reset a specific filter

Misc options:
  -q                      do not show the visible entries
  -r                      reload all entries
                            (done automatically on edit and undo)

Help options:
  -h, --help              show this help and exit
  -hf                     show info about filtering and exit (TODO)
  -hs                     show info about sorting and exit (TODO)
  -he                     show info about editing and exit (TODO)

Color modes:
  --mono                  turn off color
  --color                 use 8/16 colors [default]
  --truecolor, --24bit    use 24bit color

Path overrides:
  --config-file <PATH>    [default: '"$DEFAULT_SETTINGS_FILE"']
  --cache-path <PATH>     [default: '"$DEFAULT_CACHE_DIR"']
'
    exit 0
}

# Options needed before initialization
while test "$1"; do
    case "$1" in
        -h | --help )
            show_help
            ;;
        --config-file )
            shift
            test -z "$1" && fatal_error 'no config file path specified'
            SETTINGS_FILE="$1"
            ;;
        --cache-path )
            shift
            test -z "$1" && fatal_error 'no cache directory path specified'
            CACHE_DIR="$1"
            ;;
        * )
            break
            ;;
    esac
    shift
done


# Input files
SETTINGS_FILE="${SETTINGS_FILE-"$DEFAULT_SETTINGS_FILE"}"
ROOT="$(jq -r '.["path"]' "$SETTINGS_FILE")"
COLORMODE="$(jq -r '.["color mode"]//"color"' "$SETTINGS_FILE")"

# Cache/state files
CACHE_DIR="${CACHE_DIR-"$DEFAULT_CACHE_DIR"}"
test -d "$CACHE_DIR" || mkdir -p "$CACHE_DIR"
STATE_FILE="$CACHE_DIR/state"
UNDO_FILE="$CACHE_DIR/undo"
ENTRIES_FILE="$CACHE_DIR/entries"
VISIBLE_ENTRIES_FILE="$CACHE_DIR/visible_entries"
TAG_COLORS_FILE="$CACHE_DIR/fixedtagcolors.json"

# Fields
FIELD_METADATA_FNAME=1
FIELD_METADATA_LAST_MODIFIED=2
FIELD_LAST_MODIFIED=3
FIELD_TITLE=4
FIELD_DESC=5
FIELD_TAGS=6
FIELD_TAG_COLORS=7
FIELD_WORDCOUNT=8

# Default state
DEF_TITLE_FILTER='.*'
DEF_DESC_FILTER='.*'
DEF_TAG_FILTER=''
DEF_WORDCOUNT_FILTER='>=0'
DEF_SORT_KEY="$FIELD_TITLE"
DEF_SORT_ORDER="ascending"
test -f "$STATE_FILE" \
    || printf '%s=%s\n%s=%s\n%s=%s\n%s=%s\n%s=%s\n' \
        'title_filter' "$DEF_TITLE_FILTER" \
        'desc_filter' "$DEF_DESC_FILTER" \
        'tag_filter' "$DEF_TAG_FILTER" \
        'wordcount_filter' "$DEF_WORDCOUNT_FILTER" \
        'sort_key' "$DEF_SORT_KEY" \
        'sort_order' "$DEF_SORT_ORDER" \
        > "$STATE_FILE"

# Filters
get_state_value() {
    # $1 = key, $2 = default value
    VAL="$(sed -n '/^'"$1"'=/ s/^[^=]\+=\(.*\)$/\1/ p' "$STATE_FILE")"
    test -z "$VAL" && VAL="$2"
    printf '%s\n' "$VAL"
}
set_state_value() {
    # Remove any old matching line and add the new line
    # $1 = key, $2 = new value
    sed -i '/^'"$1"'=/d ; $a '"$1"'='"$2" "$STATE_FILE"
}
FILTER_TITLE="$(get_state_value 'title_filter' "$DEF_TITLE_FILTER")"
FILTER_DESC="$(get_state_value 'desc_filter' "$DEF_DESC_FILTER")"
FILTER_TAGS="$(get_state_value 'tag_filter' "$DEF_TAG_FILTER")"
FILTER_WORDCOUNT="$(get_state_value 'wordcount_filter' "$DEF_WORDCOUNT_FILTER")"
SORT_KEY="$(get_state_value 'sort_key' "$DEF_SORT_KEY")"
SORT_ORDER="$(get_state_value 'sort_order' "$DEF_SORT_ORDER")"

# Misc
TAB='	'  # tab character, since bash and its ilk dont like \t
SEP="$TAB"
QUIET=''
REGEN_ENTRIES=''


fix_tag_colors() {
    printf '' > "$TAG_COLORS_FILE"
    #jq -r 'to_entries | map("\(.key)\t\(.value)") | join("\n")' tagcolors.json \
    jq '.["tag colors"]' "$SETTINGS_FILE" \
      | sed -E 's/"#(.)(.)(.)"/"#\1\1\2\2\3\3"/' \
      | while read -r line ; do
        RGB=$(printf '%s\n' "$line" | sed -En 's/^.*": *"#(..)(..)(..)".*$/0x\1 0x\2 0x\3/p' )
        if test -z "$RGB" ; then
            REPL=""
        else
            # Specifically don't quote $RGB because that is supposed to be three args
            REPL="$(printf "%d;%d;%d\n" $RGB)"
        fi
        printf '%s\n' "$line" | sed -E 's/"#.{6}"/"'"$REPL"'"/' >> "$TAG_COLORS_FILE"
            #| sed -E -e 's/^(.+)\t(.+)$/"\1": "\2",/g'
    done
}


index_metadata_files() {
    fix_tag_colors
    FNAMES_FILE="$CACHE_DIR/.temp-fnames"
    METADATA_FNAMES_FILE="$CACHE_DIR/.temp-metafnames"
    WORDCOUNTS_FILE="$CACHE_DIR/.temp-wordcounts"
    MODIFYDATES_FILE="$CACHE_DIR/.temp-modifydates"
    METADATA_MODIFYDATES_FILE="$CACHE_DIR/.temp-metamodifydates"

    # Output format should be: (separated by tab)
    # metafname, meta_last_modified, last_modified, title, desc, tags,
    #   tag colors, wordcount
    find "$ROOT" -type f -name '*.metadata' | sort > "$METADATA_FNAMES_FILE"
    sed 's_/\.\([^/]\+\)\.metadata$_/\1_' "$METADATA_FNAMES_FILE" > "$FNAMES_FILE"
    xargs -d'\n' wc -w < "$FNAMES_FILE" | head -n-1 \
        | sed 's/^ *\([0-9]\+\) \+.*$/\1/' > "$WORDCOUNTS_FILE"
    xargs -d'\n' stat -c '%Y' < "$FNAMES_FILE" > "$MODIFYDATES_FILE"
    xargs -d'\n' stat -c '%Y' < "$METADATA_FNAMES_FILE" > "$METADATA_MODIFYDATES_FILE"
    # Read all the metadata files, extract the relevant things with jq,
    # and join all the stuff together with paste
    xargs -d'\n' \
        jq -r --slurpfile tag_colors "$TAG_COLORS_FILE" \
            --arg default_tag_color '102;102;119' \
            '[
                .title,
                .description,
                (.tags | sort | join(",")),
                (.tags | sort | map($tag_colors[0][.]//$default_tag_color) | join(","))
            ] | join("\t")' \
        < "$METADATA_FNAMES_FILE" \
        | paste "$METADATA_FNAMES_FILE" "$METADATA_MODIFYDATES_FILE" \
            "$MODIFYDATES_FILE" - "$WORDCOUNTS_FILE" \
        > "$ENTRIES_FILE"
}

filter_on_field() {
    FIELD="$1"
    FILTER="$2"
    sed -nE '
        # Put the whole line in the hold space (we want to print it later)
        h
        # Fields are separated by tabs, so skip FIELD number of tabs to get to
        # the right field we want to test
        s/^([^\t]*\t){'"$FIELD"'}([^\t]*)\t.*/\2/g
        # Delete the line if the pattern (case-insensitive) does not match
        /'"$FILTER"'/I !d
        # Get the whole line back from the hold space and print it
        g ; p'
}

generate_index_view() {
    # Fix tag filter string (aka get rid of them)
    FTFS='s/ *([(),|]) */\1/g'
    # Extract the tag macros from the settings file
    GET_TAG_MACROS='.["tag macros"]|to_entries|map("\(.key)\t\(.value)")|join("\n")'
    # Reverse order if descending
    REVERSE_ARG=''
    test "${SORT_ORDER?"no sort order"}" = 'descending' && REVERSE_ARG='-r'
    # Sort as a number if sorting by a numeric field
    NUM_SORT_ARG=''
    test "${SORT_KEY?"no sort key"}" = "$FIELD_WORDCOUNT" && NUM_SORT_ARG='-n'
    # Do the thing
    awk -F"${SEP?"no separator"}" -v tag_filter="$(printf '%s\n' "$FILTER_TAGS" | sed -E "$FTFS")" \
        -v raw_tag_macros="$(jq -r "$GET_TAG_MACROS" "${SETTINGS_FILE?"no settings file"}" \
                             | sed -E "$FTFS")" \
        -f tagfilter.awk "${ENTRIES_FILE?"no entries file"}" \
        | filter_on_field "$FIELD_TITLE" "$FILTER_TITLE" \
        | filter_on_field "$FIELD_DESC" "$FILTER_DESC" \
        | awk -F"${SEP?"no separator"}" \
            '{if ($'"$FIELD_WORDCOUNT"' '"$FILTER_WORDCOUNT"') {print $0}}' \
        | sort -f -t"${SEP?"no separator"}" -k"$SORT_KEY" $REVERSE_ARG $NUM_SORT_ARG \
        > "${VISIBLE_ENTRIES_FILE?"no visible entries file"}"
}


show_index_view() {
    TERMWIDTH="$(tput cols)"
    hr="$(printf "%${TERMWIDTH}s" | sed 's/ /─/g')"
    awk -F"${SEP?"no separator"}" -v full_hr="$hr" -v termwidth="$TERMWIDTH" \
        -v color_mode="${COLORMODE?"no color mode"}" \
        -f formatoutput.awk "${VISIBLE_ENTRIES_FILE?"no visible entries file"}"
}


while test "$1"; do
    case "$1" in
        --mono )
            COLORMODE="mono";
            ;;
        --color )
            COLORMODE="color";
            ;;
        --truecolor | --24bit )
            COLORMODE="truecolor";
            ;;
        -q )
            QUIET='yes'
            ;;
        -r | --reload )
            RELOAD_ENTRIES='yes'
            ;;
        -lt )
            printf '[1m  Tags:[0m\n'
            cut -d"$SEP" -f"$FIELD_TAGS" "$ENTRIES_FILE" | grep '.' | tr ',' '\n' \
                | sort | uniq -c | sort -nr | column
            #cut -d"$SEP" -f$FIELD_TAGS,$FIELD_TAG_COLORS "$ENTRIES_FILE" | grep '.' \
                #| awk -F"$SEP" '{split($1,t,",");split($2,c,",");for(x in t){print c[x] "\t" t[x]}}'\
                #| sort -t"$SEP" -k2 | uniq -c -f1 | sort -nr | column
                #| sed -E 's/,([0-9 ]+) ([0-9;]+)\t([^,]+)/\1 [38;2;0;0;0;48;2;\2m \3 [0m/g'
            QUIET='yes'
            ;;
        -s )
            # Show current sort key
            unset SORT_KEY_NAME
            if test "$SORT_KEY" = "$FIELD_LAST_MODIFIED"; then
                SORT_KEY_NAME='last modified date'
            elif test "$SORT_KEY" = "$FIELD_TITLE"; then
                SORT_KEY_NAME='title'
            elif test "$SORT_KEY" = "$FIELD_WORDCOUNT"; then
                SORT_KEY_NAME='wordcount'
            fi
            printf 'current sort key: %s\n' "${SORT_KEY_NAME?"unknown sort key: $SORT_KEY"}"
            QUIET='yes'
            ;;
        -s? | -s?- )
            # Sort
            ARG="${1#-s}"
            SORT_ORDER='ascending'
            # Set order to reverse if there's a trailing dash
            test -z "${1#-s?}" || { SORT_ORDER='descending' ; ARG="${ARG%-}" ; }
            case "$ARG" in
                n ) SORT_KEY="$FIELD_TITLE" ;;
                c ) SORT_KEY="$FIELD_WORDCOUNT" ;;
                m ) SORT_KEY="$FIELD_LAST_MODIFIED" ;;
                * )
                    fatal_error "invalid sort key: $SORT_KEY"
                    ;;
            esac
            REGEN_ENTRIES='yes'
            ;;
        -f )
            printf 'Active filters:\n  title: %s\n  desc: %s\n  tags: %s\n  wordcount: %s\n' \
                "$FILTER_TITLE" "$FILTER_DESC" "$FILTER_TAGS" "$FILTER_WORDCOUNT"
            QUIET='yes'
            ;;
        -f0 )
            # Reset all filters
            FILTER_TITLE="$DEF_TITLE_FILTER"
            FILTER_DESC="$DEF_DESC_FILTER"
            FILTER_TAGS="$DEF_TAG_FILTER"
            FILTER_WORDCOUNT="$DEF_WORDCOUNT_FILTER"
            REGEN_ENTRIES='yes'
            ;;
        -f?0 )
            # Reset a specific filter
            FILTER_KEY="${1#-f}"
            case "$FILTER_KEY" in
                n0 )
                    FILTER_TITLE="$DEF_TITLE_FILTER"
                    printf 'resetting title filter\n'
                    ;;
                d0 )
                    FILTER_DESC="$DEF_DESC_FILTER"
                    printf 'resetting description filter\n'
                    ;;
                t0 )
                    FILTER_TAGS="$DEF_TAG_FILTER"
                    printf 'resetting tag filter\n'
                    ;;
                c0 )
                    FILTER_WORDCOUNT="$DEF_WORDCOUNT_FILTER"
                    printf 'resetting wordcount filter\n'
                    ;;
                * )
                    fatal_error "invalid filter key: $ARG"
                    ;;
            esac
            REGEN_ENTRIES='yes'
            ;;
        -f? )
            # Filter
            FILTER_KEY="${1#-f}"
            shift
            test -z "$1" && fatal_error 'no filter specified'
            FILTER_ARG="$1"
            case "$FILTER_KEY" in
                n ) FILTER_TITLE="$FILTER_ARG" ;;
                d ) FILTER_DESC="$FILTER_ARG" ;;
                t ) FILTER_TAGS="$FILTER_ARG" ;;
                c )
                    printf '%s\n' "$FILTER_ARG" | grep -qE '^([<>]=?|==) *[0-9]+$' \
                        || fatal_error "invalid wordcount filter: $FILTER_ARG"
                    FILTER_WORDCOUNT="$FILTER_ARG"
                    ;;
                * )
                    fatal_error "invalid filter key: $FILTER_KEY"
                    ;;
            esac
            REGEN_ENTRIES='yes'
            ;;
        -u )
            # Undo format: (separated by tabs)
            #   <checksum and filesize> <filename> <old data>
            LAST_UNDO="$(tail -n1 "$UNDO_FILE")"
            if test -z "$LAST_UNDO" ; then
                printf 'Nothing to undo\n'
            else
                UNDO_CHECKSUM="$(printf '%s\n' "$LAST_UNDO" | cut -d"$TAB" -f1)"
                ENTRY_FNAME="$(printf '%s\n' "$LAST_UNDO" | cut -d"$TAB" -f2)"
                CURRENT_CHECKSUM="$(cksum "$ENTRY_FNAME")"
                # Check if the file has been changed since the undo was created
                if test "$UNDO_CHECKSUM $ENTRY_FNAME" = "$CURRENT_CHECKSUM" ; then
                    # Dump the data into the metadata file
                    tail -n1 "$UNDO_FILE" | cut -d"$TAB" -f3 | jq '.' > "$ENTRY_FNAME"
                    # Remove the undo
                    sed -i '$d' "$UNDO_FILE"
                else
                    printf 'The file "%s" has changed since the undo was made!\n' "$ENTRY_FNAME"
                    printf 'Remove the last line in the undo file or stop undoing.\n'
                    # TODO: force undo and/or confirm y/n
                fi
                RELOAD_ENTRIES='yes'
            fi
            ;;
        -e[0-9]* )
            test -z "$EDITOR" && fatal_error 'no $EDITOR specified'
            ENTRY_NUM="${1#-e}"
            printf '%s\n' "$ENTRY_NUM" | grep -qE '^[0-9]$' || fatal_error "entry index is not a number: $ENTRY_NUM"
            # Get the entry data from the visible entries cache
            ENTRY="$(sed -n "$((ENTRY_NUM + 1)) p" "$VISIBLE_ENTRIES_FILE")"
            test -z "$ENTRY" && fatal_error "invalid entry index: $ENTRY_NUM"
            ENTRY_FNAME="$(printf '%s\n' "$ENTRY" | cut -d"$SEP" -f"$FIELD_METADATA_FNAME")"
            # Prepare undo
            OLD_CHECKSUM="$(cksum "$ENTRY_FNAME")"
            OLD_DATA="$(jq -c '.' "$ENTRY_FNAME")"
            "$EDITOR" "$ENTRY_FNAME"
            NEW_CHECKSUM="$(cksum "$ENTRY_FNAME")"
            if test "$OLD_CHECKSUM" = "$NEW_CHECKSUM" ; then
                printf 'no changes were made\n'
            else
                printf '%s\n%s\n' "$NEW_CHECKSUM" "$OLD_DATA" \
                    | sed '
                        # cksums format is <checksum> <bytecount> <filename>
                        # Replace the second space with tab
                        # but avoid potential space in the filename
                        s/ /\t/2
                        # s/^\([0-9]*\) \([0-9]*\) /\1\t\2\t/
                        # Append the data row, and replace the newline with tab
                        N; y/\n/\t/' \
                    >> "$UNDO_FILE"
                RELOAD_ENTRIES='yes'
            fi
            QUIET='yes'
            ;;
        * )
            fatal_error "invalid argument: $1"
            ;;
    esac
    shift
done

if test -z "$QUIET" ; then
    if test -n "$RELOAD_ENTRIES" || test ! -f "$ENTRIES_FILE" ; then
        index_metadata_files
        REGEN_ENTRIES='yes'
    fi
    if test -n "$REGEN_ENTRIES" || test ! -f "$VISIBLE_ENTRIES_FILE" ; then
        generate_index_view
    fi
    show_index_view
fi

# Save state
set_state_value 'title_filter' "$FILTER_TITLE"
set_state_value 'desc_filter' "$FILTER_DESC"
set_state_value 'tag_filter' "$FILTER_TAGS"
set_state_value 'wordcount_filter' "$FILTER_WORDCOUNT"
set_state_value 'sort_key' "$SORT_KEY"
set_state_value 'sort_order' "$SORT_ORDER"
