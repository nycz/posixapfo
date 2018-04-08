#!/bin/sh

# Input files
SETTINGSFILE="$HOME/.config/sapfo/settings.json"
ROOT="$(jq -r '.["path"]' "$SETTINGSFILE")"
COLORMODE="$(jq -r '.["color mode"]//"color"' "$SETTINGSFILE")"
TAGCOLORFILE="tagcolors.json"

CACHEFILE=metadata.json
CACHEDCOLORS=fixedtagcolors.json


# Fields
# metafname = 1
# meta last modified = 2
FIELD_LAST_MODIFIED=3
FIELD_TITLE=4
FIELD_DESC=5
FIELD_TAGS=6
FIELD_TAG_COLORS=7
FIELD_WORDCOUNT=8

SORT_KEY=$FIELD_TITLE

# Filters
FILTER_TAGS=''
FILTER_DESC='.'
FILTER_TITLE='.'
FILTER_WORDCOUNT=''

# Misc
QUIET=''
SEP='	'  # tab character, since bash and its ilk dont like \t


fix_tag_colors() {
    printf '' > "$CACHEDCOLORS"
    #jq -r 'to_entries | map("\(.key)\t\(.value)") | join("\n")' tagcolors.json \
    jq '.["tag colors"]' "$SETTINGSFILE" \
      | sed -E 's/"#(.)(.)(.)"/"#\1\1\2\2\3\3"/' \
      | while read line ; do
        RGB=$(printf '%s\n' "$line" | sed -En 's/^.*": *"#(..)(..)(..)".*$/0x\1 0x\2 0x\3/p' )
        if test -z "$RGB" ; then
            REPL=""
        else
            # Specifically don't quote $RGB because that is supposed to be three args
            REPL="$(printf "%d;%d;%d\n" $RGB)"
        fi
        printf '%s\n' "$line" | sed -E 's/"#.{6}"/"'"$REPL"'"/' >> "$CACHEDCOLORS"
            #| sed -E -e 's/^(.+)\t(.+)$/"\1": "\2",/g'
    done
}

generate_cache() {
    # TODO: fix this more
    fix_tag_colors
    ALL_FILES="$(find "$ROOT" -type f -name '*.metadata' | sort | while read f; do printf '%s\t%s\t%s\n' "$f" $(stat -c '%Y' "$f") $(stat -c '%Y' "$(dirname "$f")/$(basename "$f" | sed "$DEXT")") ; done)"
    CACHED_FILES="$(cut -f1-3 metadata.json)"
    printf '%s' "$ALL_FILES" > allfiles
    printf '%s' "$CACHED_FILES" > cachedfiles
    diff allfiles cachedfiles
    X=$((16#FF))
}


index_metadata_file() {
    METAFNAME="$1"
    FNAME="$(basename "$METAFNAME")"
    FNAME="${FNAME%.*}"
    FNAME="$(dirname "$METAFNAME")/${FNAME#.}"
    WORDS="$(wc -w "$FNAME" | cut -d' ' -f1)"
    METAMODIFYDATE="$(stat -c '%Y' "$METAFNAME")"
    MODIFYDATE="$(stat -c '%Y' "$FNAME")"
    jq -rc --slurpfile tag_colors "$CACHEDCOLORS" --arg default_tag_color '102;102;119' '
        [
            $metafile,
            $meta_last_modified,
            $last_modified,
            .title,
            .description,
            #(.tags | sort | map(gsub(" "; "_") | "#\(.),") | join("")),
            (.tags | sort | join(",")),
            (.tags | sort | map($tag_colors[0][.]//$default_tag_color) | join(",")),
            $length
        ] | join("\t")
        ' \
        --arg metafile "$METAFNAME" \
        --arg length "$WORDS" \
        --arg meta_last_modified "$METAMODIFYDATE" \
        --arg last_modified "$MODIFYDATE" \
        "$METAFNAME" >> "$CACHEFILE"
}

show_index_view() {
    TERMWIDTH="$(tput cols)"
    hr="$(printf "%${TERMWIDTH}s" | sed 's/ /─/g')"
    awk -F"$SEP" -v tag_filter=""$(printf "%s\n" "$FILTER_TAGS" | sed -E 's/ *([(),|]) */\1/g')"" \
        -f tagfilter.awk "$CACHEFILE" \
        | sed -n 'h; s/^\([^\t]*\t\)\{3\}\([^\t]*\)\t.*/\2/g ; /'"$FILTER_TITLE"'/I !d ; g ; p' \
        | sed -n 'h; s/^\([^\t]*\t\)\{4\}\([^\t]*\)\t.*/\2/g ; /'"$FILTER_DESC"'/I !d ; g ; p' \
        | sort -h -t"$SEP" -k"$SORT_KEY" \
        | awk -F"$SEP" -v full_hr="$hr" -v termwidth="$TERMWIDTH" -v color_mode="$COLORMODE" \
            -f formatoutput.awk
}


while test "$1"; do
    case "$1" in
        --mono )
            COLORMODE="mono";
            ;;
        --truecolor | --24bit )
            COLORMODE="truecolor";
            ;;
        -r | --reload )
            fix_tag_colors
            printf '' > "$CACHEFILE"
            find "$ROOT" -type f -name '*.metadata' | sort \
                | while read f ; do
                index_metadata_file "$f"
            done
            QUIET='yes'
            #generate_cache "$2"
            ;;
        t | tags )
            fix_tag_colors
            ;;
        -lt )
            printf '[1m  Tags:[0m\n'
            cut -d"$SEP" -f"$FIELD_TAGS" "$CACHEFILE" | grep '.' | tr ',' '\n' \
                | sort | uniq -c | sort -nr | column
            #cut -d"$SEP" -f$FIELD_TAGS,$FIELD_TAG_COLORS "$CACHEFILE" | grep '.' \
                #| awk -F"$SEP" '{split($1,t,",");split($2,c,",");for(x in t){print c[x] "\t" t[x]}}'\
                #| sort -t"$SEP" -k2 | uniq -c -f1 | sort -nr | column
                #| sed -E 's/,([0-9 ]+) ([0-9;]+)\t([^,]+)/\1 [38;2;0;0;0;48;2;\2m \3 [0m/g'
            QUIET='yes'
            ;;
        -s? )
            ARG="${1#-s}"
            case "$ARG" in
                d ) SORT_KEY="$FIELD_DESC" ;;
                n ) SORT_KEY="$FIELD_TITLE" ;;
                c ) SORT_KEY="$FIELD_WORDCOUNT" ;;
                m ) SORT_KEY="$FIELD_LAST_MODIFIED" ;;
                * )
                    printf 'error: invalid sort key: "%s"\n' "$ARG"
                    exit 1
                    ;;
            esac
            ;;
        -ft )
            shift
            if test -z "$1" ; then
                printf 'error: no tag filter specified\n'
                exit 1
            fi
            FILTER_TAGS="$1"
            ;;
        -f? )
            FILTER_KEY="${1#-f}"
            shift
            if test -z "$1" ; then
                printf 'error: no filter specified\n'
                exit 1
            fi
            FILTER_ARG="$1"
            case "$FILTER_KEY" in
                d ) FILTER_DESC="$FILTER_ARG" ;;
                n ) FILTER_TITLE="$FILTER_ARG" ;;
                * )
                    printf 'error: invalid filter key: "%s"\n' "$ARG"
                    exit 1
                    ;;
            esac
            ;;
        * )
            printf 'error: invalid argument: "%s"\n' "$1"
            exit 1
            ;;
    esac
    shift
done


test -z "$QUIET" && show_index_view
