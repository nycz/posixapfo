#!/bin/sh
default_settings_file="$HOME/.config/sapfo/settings.json"
default_cache_dir="$HOME/.cache/sapfo"
settings_file=''


fatal_error() {
    # $1 = message, $2 = exit code (optional)
    error_prefix='Error: '
    if test "$colormode" = 'mono' ; then
        printf '%s%s\n' "$error_prefix" "$1" >&2
    else
        printf '%s%s%s%s\n' '[1;31m' "$error_prefix" '[0m' "$1" >&2
    fi
    exit "${2-1}"  # default to exit code 1
}


exit_on_error() {
    # Helper function for when fatal_error has been run in a subshell
    _exit_code="$?"
    test "$_exit_code" -eq "0" || exit "$_exit_code"
}


show_help() {
    scriptname="$(basename "$0")"
    printf '%s' \
'Usage:
  '"$scriptname"' [path-overrides] [options]
  '"$scriptname"' -h | --help | (specific-help-topics)

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

Backstory:
  -b                      show backstory pages of last chosen entry
  -b<NUM>                 show backstory pages of the entry with index <NUM>

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
  --config-file <PATH>    [default: '"$default_settings_file"']
  --cache-path <PATH>     [default: '"$default_cache_dir"']
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
            settings_file="$1"
            ;;
        --cache-path )
            shift
            test -z "$1" && fatal_error 'no cache directory path specified'
            cache_dir="$1"
            ;;
        * )
            break
            ;;
    esac
    shift
done


# Input files
test -z "$settings_file" && settings_file="$default_settings_file"
root="$(jq -r '.["path"]' "$settings_file")"
colormode="$(jq -r '.["color mode"]//"color"' "$settings_file")"

# Cache/state files
test -z "$cache_dir" && cache_dir="$default_cache_dir"
test -d "$cache_dir" || mkdir -p "$cache_dir"
state_file="$cache_dir/state"
undo_file="$cache_dir/undo"
entries_file="$cache_dir/entries"
visible_entries_file="$cache_dir/visible_entries"
tag_colors_file="$cache_dir/fixedtagcolors.json"
active_backstory_file="$cache_dir/backstory_pages"

# Fields
field_metadata_fname=1
field_metadata_last_modified=2
field_last_modified=3
field_title=4
field_desc=5
field_tags=6
field_tag_colors=7
field_wordcount=8

# Default state
def_title_filter='.*'
def_desc_filter='.*'
def_tag_filter=''
def_wordcount_filter='>=0'
def_sort_key="$field_title"
def_sort_order='ascending'
def_active_backstory_dir=''
test ! -f "$state_file" \
    && {
        printf 'title_filter=%s\n' "$def_title_filter"
        printf 'desc_filter=%s\n' "$def_desc_filter"
        printf 'tag_filter=%s\n' "$def_tag_filter"
        printf 'wordcount_filter=%s\n' "$def_wordcount_filter"
        printf 'sort_key=%s\n' "$def_sort_key"
        printf 'sort_order=%s\n' "$def_sort_order"
        printf 'active_backstory_dir=%s\n' "$def_active_backstory_dir"
    } > "$state_file"

# Filters
get_state_value() {
    # $1 = key, $2 = default value
    val="$(sed -n '/^'"$1"'=/ s/^[^=]\+=\(.*\)$/\1/ p' "$state_file")"
    test -z "$val" && val="$2"
    printf '%s\n' "$val"
}
set_state_value() {
    # Remove any old matching line and add the new line
    # $1 = key, $2 = new value
    sed -i '/^'"$1"'=/d ; $a '"$1"'='"$2" "$state_file"
}
filter_title="$(get_state_value 'title_filter' "$def_title_filter")"
filter_desc="$(get_state_value 'desc_filter' "$def_desc_filter")"
filter_tags="$(get_state_value 'tag_filter' "$def_tag_filter")"
filter_wordcount="$(get_state_value 'wordcount_filter' "$def_wordcount_filter")"
sort_key="$(get_state_value 'sort_key' "$def_sort_key")"
sort_order="$(get_state_value 'sort_order' "$def_sort_order")"
active_backstory_dir="$(get_state_value 'active_backstory_dir' "$def_active_backstory_dir")"

# View modes
index_view='index'
backstory_view='backstory'
view_mode="$index_view"

# Misc
tab='	'  # tab character, since bash and its ilk dont like \t
sep="$tab"
regen_entries=''
regen_backstory=''

fix_tag_colors() {
    printf '' > "$tag_colors_file"
    #jq -r 'to_entries | map("\(.key)\t\(.value)") | join("\n")' tagcolors.json \
    jq '.["tag colors"]' "$settings_file" \
      | sed -E 's/"#(.)(.)(.)"/"#\1\1\2\2\3\3"/' \
      | while read -r line ; do
        rgb=$(printf '%s\n' "$line" | sed -En 's/^.*": *"#(..)(..)(..)".*$/0x\1 0x\2 0x\3/p' )
        if test -z "$rgb" ; then
            repl=''
        else
            # Specifically don't quote $rgb because that is supposed to be three args
            # shellcheck disable=SC2183,SC2086
            repl="$(printf '%d;%d;%d\n' $rgb)"
        fi
        printf '%s\n' "$line" | sed -E 's/"#.{6}"/"'"$repl"'"/' >> "$tag_colors_file"
            #| sed -E -e 's/^(.+)\t(.+)$/"\1": "\2",/g'
    done
}


# Ignore warning about dollar signs in single quoted strings
# shellcheck disable=SC2016
index_metadata_files() {
    fix_tag_colors
    fnames_file="$cache_dir/.temp-fnames"
    metadata_fnames_file="$cache_dir/.temp-metafnames"
    wordcounts_file="$cache_dir/.temp-wordcounts"
    modifydates_file="$cache_dir/.temp-modifydates"
    metadata_modifydates_file="$cache_dir/.temp-metamodifydates"

    # Output format should be: (separated by tab)
    # metafname, meta_last_modified, last_modified, title, desc, tags,
    #   tag colors, wordcount
    find "$root" -type f -name '*.metadata' | sort > "$metadata_fnames_file"
    sed 's_/\.\([^/]\+\)\.metadata$_/\1_' "$metadata_fnames_file" > "$fnames_file"
    xargs -d'\n' wc -w < "$fnames_file" | head -n-1 \
        | sed 's/^ *\([0-9]\+\) \+.*$/\1/' > "$wordcounts_file"
    xargs -d'\n' stat -c '%Y' < "$fnames_file" > "$modifydates_file"
    xargs -d'\n' stat -c '%Y' < "$metadata_fnames_file" > "$metadata_modifydates_file"
    # Read all the metadata files, extract the relevant things with jq,
    # and join all the stuff together with paste
    # Also, ignore the warning abt reading from and writing to the same file
    # shellcheck disable=SC2094
    xargs -d'\n' \
        jq -r --slurpfile tag_colors "$tag_colors_file" \
            --arg default_tag_color '102;102;119' \
            '[
                .title,
                .description,
                (.tags | sort | join(",")),
                (.tags | sort | map($tag_colors[0][.]//$default_tag_color) | join(","))
            ] | join("\t")' \
        < "$metadata_fnames_file" \
        | paste "$metadata_fnames_file" "$metadata_modifydates_file" \
                "$modifydates_file" - "$wordcounts_file" \
        > "$entries_file"
}

filter_on_field() {
    field="$1"
    filter="$2"
    sed -nE '
        # Put the whole line in the hold space (we want to print it later)
        h
        # Fields are separated by tabs, so skip field number of tabs to get to
        # the right field we want to test
        s/^([^\t]*\t){'"$((field - 1))"'}([^\t]*)\t.*/\2/g
        # Delete the line if the pattern (case-insensitive) does not match
        /'"$filter"'/I !d
        # Get the whole line back from the hold space and print it
        g ; p'
}

generate_index_view() {
    # Fix tag filter string (aka get rid of them)
    ftfs='s/ *([(),|]) */\1/g'
    # Extract the tag macros from the settings file
    get_tag_macros='.["tag macros"]|to_entries|map("\(.key)\t\(.value)")|join("\n")'
    # Reverse order if descending
    reverse_arg=''
    test "$sort_order" = 'descending' && reverse_arg='-r'
    # Sort as a number if sorting by a numeric field
    num_sort_arg=''
    test "$sort_key" = "$field_wordcount" && num_sort_arg='-n'
    # Do the thing
    awk -F"$sep" -v tag_filter="$(printf '%s\n' "$filter_tags" | sed -E "$ftfs")" \
        -v raw_tag_macros="$(jq -r "$get_tag_macros" "$settings_file" \
                             | sed -E "$ftfs")" \
        -f tagfilter.awk "$entries_file" \
        | filter_on_field "$field_title" "$filter_title" \
        | filter_on_field "$field_desc" "$filter_desc" \
        | awk -F"$sep" \
            '{if ($'"$field_wordcount"' '"$filter_wordcount"') {print $0}}' \
        | sort -f -t"$sep" -k"$sort_key" $reverse_arg $num_sort_arg \
        > "$visible_entries_file"
}

generate_backstory_view() {
    test -z "$active_backstory_dir" && fatal_error 'no entry selected'
    backstory_pages_file="$cache_dir/.temp-backstory-files"
    backstory_wordcount_file="$cache_dir/.temp-backstory-wordcount"
    # Find relevant filenames
    find "$active_backstory_dir" -type f \! -regex '.*\.rev[0-9]+' > "$backstory_pages_file"
    # Wordcounts for each backstory page
    xargs -d'\n' wc -w < "$backstory_pages_file" | head -n-1 \
        | sed 's/^ *\([0-9]\+\) \+.*$/\1/' > "$backstory_wordcount_file"
    # Json metadata for each backstory page
    xargs -d'\n' head -qn1 < "$backstory_pages_file"\
        | awk '{printf("{\"__metawordcount\": \"%d\", %s\n", NF, substr($0, 2))}' \
        | jq -r --arg sep "$sep" \
            '[.title, .revision, .__metawordcount] | map(tostring) | join($sep)'\
        | paste "$backstory_pages_file" - "$backstory_wordcount_file"\
        | sort -t"$sep" -k2 > "$active_backstory_file"
}

show_view() {
    _mode="$1"
    _filename="$2"
    termwidth="$(tput cols)"
    hr="$(printf "%${termwidth}s" | sed 's/ /─/g')"
    awk -F"$sep" -v full_hr="$hr" -v termwidth="$termwidth" \
        -v color_mode="$colormode" \
        -v view_mode="$_mode" \
        -f 'formatoutput.awk' "$_filename"
}

show_index_view() {
    show_view 'index' "$visible_entries_file"
}

show_backstory_view() {
    show_view 'backstory' "$active_backstory_file"
}

parse_entry_number() {
    _entry_num="$1"
    # The number has to actually be a number
    case "$_entry_num" in
        ''|*[!0-9]*) fatal_error "entry index is not a number: $_entry_num" ;;
    esac
    # Get the entry data from the visible entries cache
    _entry="$(sed -n "$((_entry_num + 1)) p" "$visible_entries_file")"
    test -z "$_entry" && fatal_error "invalid entry index: $_entry_num"
    printf '%s\n' "$_entry"
}

while test "$1"; do
    case "$1" in
        --mono )
            colormode="mono";
            ;;
        --color )
            colormode="color";
            ;;
        --truecolor | --24bit )
            colormode="truecolor";
            ;;
        -q )
            view_mode=''
            ;;
        -r | --reload )
            reload_entries='yes'
            ;;
        -lt )
            printf '[1m  Tags:[0m\n'
            cut -d"$sep" -f"$field_tags" "$entries_file" | grep '.' | tr ',' '\n' \
                | sort | uniq -c | sort -nr | column
            #cut -d"$sep" -f$field_tags,$field_tag_colors "$entries_file" | grep '.' \
                #| awk -F"$sep" '{split($1,t,",");split($2,c,",");for(x in t){print c[x] "\t" t[x]}}'\
                #| sort -t"$sep" -k2 | uniq -c -f1 | sort -nr | column
                #| sed -E 's/,([0-9 ]+) ([0-9;]+)\t([^,]+)/\1 [38;2;0;0;0;48;2;\2m \3 [0m/g'
            # TODO: taglist viewmode
            view_mode=''
            ;;
        -b )
            if test ! -f "$active_backstory_file" ; then
                printf 'No entry selected to view backstory for\n'
                exit 0
            fi
            view_mode="$backstory_view"
            ;;
        -b[0-9]* )
            entry="$(parse_entry_number "${1#-b}")"
            exit_on_error
            # shellcheck disable=SC2016
            entry_fname="$(printf '%s\n' "$entry"\
                | cut -d"$sep" -f"$field_metadata_fname"\
                | sed 's_/\.\([^/]\+\)\.metadata$_/\1_')"
            metadir="${entry_fname}.metadir"
            if test -d "$metadir" ; then
                view_mode="$backstory_view"
                active_backstory_dir="$metadir"
                regen_backstory='yes'
            else
                view_mode=''
                printf 'No backstory files\n'
            fi
            ;;
        -s )
            # Show current sort key
            sort_key_name=''
            if test "$sort_key" = "$field_last_modified"; then
                sort_key_name='last modified date'
            elif test "$sort_key" = "$field_title"; then
                sort_key_name='title'
            elif test "$sort_key" = "$field_wordcount"; then
                sort_key_name='wordcount'
            else
                fatal_error "invalid sort key: $sort_key"
            fi
            printf 'current sort key: %s\n' "$sort_key_name"
            view_mode=''
            ;;
        -s? | -s?- )
            # Sort
            arg="${1#-s}"
            sort_order='ascending'
            # Set order to reverse if there's a trailing dash
            test -z "${1#-s?}" || { sort_order='descending' ; arg="${arg%-}" ; }
            case "$arg" in
                n ) sort_key="$field_title" ;;
                c ) sort_key="$field_wordcount" ;;
                m ) sort_key="$field_last_modified" ;;
                * ) fatal_error "invalid sort key: $sort_key" ;;
            esac
            regen_entries='yes'
            ;;
        -f )
            printf 'Active filters:\n  title: %s\n  desc: %s\n  tags: %s\n  wordcount: %s\n' \
                "$filter_title" "$filter_desc" "$filter_tags" "$filter_wordcount"
            # TODO: maybe active filter view mode?
            view_mode=''
            ;;
        -f0 )
            # Reset all filters
            filter_title="$def_title_filter"
            filter_desc="$def_desc_filter"
            filter_tags="$def_tag_filter"
            filter_wordcount="$def_wordcount_filter"
            regen_entries='yes'
            ;;
        -f?0 )
            # Reset a specific filter
            filter_key="${1#-f}"
            case "$filter_key" in
                n0 )
                    filter_title="$def_title_filter"
                    printf 'resetting title filter\n'
                    ;;
                d0 )
                    filter_desc="$def_desc_filter"
                    printf 'resetting description filter\n'
                    ;;
                t0 )
                    filter_tags="$def_tag_filter"
                    printf 'resetting tag filter\n'
                    ;;
                c0 )
                    filter_wordcount="$def_wordcount_filter"
                    printf 'resetting wordcount filter\n'
                    ;;
                * )
                    fatal_error "invalid filter key: $arg"
                    ;;
            esac
            regen_entries='yes'
            ;;
        -f? )
            # Filter
            filter_key="${1#-f}"
            shift
            test -z "$1" && fatal_error 'no filter specified'
            filter_arg="$1"
            case "$filter_key" in
                n ) filter_title="$filter_arg" ;;
                d ) filter_desc="$filter_arg" ;;
                t ) filter_tags="$filter_arg" ;;
                c )
                    printf '%s\n' "$filter_arg" | grep -qE '^([<>]=?|==) *[0-9]+$' \
                        || fatal_error "invalid wordcount filter: $filter_arg"
                    filter_wordcount="$filter_arg"
                    ;;
                * )
                    fatal_error "invalid filter key: $filter_key"
                    ;;
            esac
            regen_entries='yes'
            ;;
        -u )
            # Undo format: (separated by tabs)
            #   <checksum and filesize> <filename> <old data>
            last_undo="$(tail -n1 "$undo_file")"
            if test -z "$last_undo" ; then
                printf 'Nothing to undo\n'
            else
                undo_checksum="$(printf '%s\n' "$last_undo" | cut -d"$tab" -f1)"
                entry_fname="$(printf '%s\n' "$last_undo" | cut -d"$tab" -f2)"
                current_checksum="$(cksum "$entry_fname")"
                # Check if the file has been changed since the undo was created
                if test "$undo_checksum $entry_fname" = "$current_checksum" ; then
                    # Dump the data into the metadata file
                    tail -n1 "$undo_file" | cut -d"$tab" -f3 | jq '.' > "$entry_fname"
                    # Remove the undo
                    sed -i '$d' "$undo_file"
                else
                    printf 'The file "%s" has changed since the undo was made!\n' "$entry_fname"
                    printf 'Remove the last line in the undo file or stop undoing.\n'
                    # todo: force undo and/or confirm y/n
                fi
                reload_entries='yes'
            fi
            ;;
        -e[0-9]* )
            test -z "$EDITOR" && fatal_error 'no EDITOR environment variable specified'
            entry="$(parse_entry_number "${1#-e}")"
            exit_on_error
            entry_metadata_fname="$(printf '%s\n' "$entry"\
                | cut -d"$sep" -f"$field_metadata_fname")"
            # Prepare undo
            old_checksum="$(cksum "$entry_metadata_fname")"
            old_data="$(jq -c '.' "$entry_metadata_fname")"
            "$EDITOR" "$entry_metadata_fname"
            new_checksum="$(cksum "$entry_metadata_fname")"
            if test "$old_checksum" = "$new_checksum" ; then
                printf 'no changes were made\n'
            else
                printf '%s\n%s\n' "$new_checksum" "$old_data" \
                    | sed '
                        # cksums format is <checksum> <bytecount> <filename>
                        # Replace the second space with tab
                        # but avoid potential space in the filename
                        s/ /\t/2
                        # s/^\([0-9]*\) \([0-9]*\) /\1\t\2\t/
                        # Append the data row, and replace the newline with tab
                        N; y/\n/\t/' \
                    >> "$undo_file"
                reload_entries='yes'
            fi
            view_mode=''
            ;;
        * )
            fatal_error "invalid argument: $1"
            ;;
    esac
    shift
done

if test "$view_mode" = "$index_view" ; then
    if test -n "$reload_entries" || test ! -f "$entries_file" ; then
        index_metadata_files
        regen_entries='yes'
    fi
    if test -n "$regen_entries" || test ! -f "$visible_entries_file" ; then
        generate_index_view
    fi
    show_index_view
elif test "$view_mode" = "$backstory_view" ; then
    if test -n "$regen_backstory" ; then
        generate_backstory_view
    fi
    show_backstory_view
fi

# Save state
set_state_value 'title_filter' "$filter_title"
set_state_value 'desc_filter' "$filter_desc"
set_state_value 'tag_filter' "$filter_tags"
set_state_value 'wordcount_filter' "$filter_wordcount"
set_state_value 'sort_key' "$sort_key"
set_state_value 'sort_order' "$sort_order"
