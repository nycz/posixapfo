#!/bin/awk -f
#
# Inputs: (provide with -v)
#   view_mode - index/backstory
#   full_hr - a string to be used as horizontal line between entries
#   termwidth - the width of the terminal
#   color_mode - truecolor/color/mono
#   header - (optional) text to be printed above the first entry
#
# stdin should be a list of tab-seperated values, see the main part
# of this program for details on individual values
#

#'main'                    bg='#233'),
#'title'        fg='#cdd', extra=BOLD),
#'tags'         fg='#011', bg='#667'),
#'no tags'      fg='#f65', extra=ITALIC),
#'desc'         fg='#899'),
#'empty desc'   fg='#d96', extra=ITALIC),
#'id'           fg='#677', extra=ITALIC),
#'length'       fg='#677', extra=ITALIC),
#'hr'           fg='#000'),

BEGIN {
    # Formatting
    #   1 - bold
    #   3 - italic
    #   22 - normal color or intensity (aka not bold)
    #   23 - not italic, not fraktur
    #   39 - reset foreground
    #   [K - fill line

    # Color modes
    TC = "truecolor";
    COLOR = "color";
    MONO = "mono";
    # Color targets
    BG = "background";
    HEADER = "header";
    NUM = "number";
    TITLE = "title";
    TAG = "tag";
    DESC = "desc";
    REV = "revision";
    HR = "hr";
    # Mode: True color
    fmt[BG TC] = "[39;22;23;48;2;34;51;51m";
    fmt[NUM TC] = "[22;38;2;102;119;119;3m";
    fmt[TITLE TC] = "[23;38;2;204;221;221;1m";
    fmt[TAG TC] = "[22;23;38;2;0;17;17;48;2;";
    fmt[DESC TC] = "[22;23;38;2;136;153;153m";
    fmt[REV TC] = "[22;23;38;2;106;185;201m";
    fmt[HR TC] = "[22;23;38;2;0;0;0m";
    fmt[HEADER TC] = "[23;38;2;204;221;221;1m";
    fmt[HEADERLINE TC] = "[23;38;2;80;165;190;1m";
    # Mode: Color (8/16)
    fmt[BG COLOR] = "[0m";
    fmt[HEADER COLOR] = "[0;1m";
    fmt[NUM COLOR] = "[0m";
    fmt[TITLE COLOR] = "[0;1m";
    fmt[TAG COLOR] = "[0;30;46m";
    fmt[DESC COLOR] = "[0m";
    fmt[REV COLOR] = "[0m";
    fmt[HR COLOR] = "[0;90m";
    fmt[HEADERLINE COLOR] = "[0m";
    # Mode: Monochrome
    fmt[BG MONO] = "[0m";
    fmt[NUM MONO] = "[0m";
    fmt[HEADER MONO] = "[1m";
    fmt[TITLE MONO] = "[1m";
    fmt[TAG MONO] = "[0;7m";
    fmt[DESC MONO] = "";
    fmt[REV MONO] = "";
    fmt[HR MONO] = "";
    fmt[HEADERLINE MONO] = "";
    # Misc formatting
    if (!full_hr) {
        hr = "-";
    } else {
        hr = substr(full_hr, 5);
    }
    fmt_reset = "[0m";
    # Init stuff
    if (!color_mode) {
        color_mode = COLOR;
    }
    if (!termwidth) {
        termwidth = 80;
    }
    entry_index = 0;
}
function wrap(text, rel_pos, pos, wrapped_text) {
    # taken from https://github.com/svnpenn/velour/blob/267e0ed/libstd.awk#L52-L66
    while (text) {
        # Find the next pos of a space or the end (only NAWK/GAWK tho)
        rel_pos = match(text, / |$/);
        pos += rel_pos;
        # Move to next row if past max_width
        if (pos > termwidth - 4) {
            wrapped_text = wrapped_text "\n";
            pos = rel_pos - 1;
        }
        # Add a SPAAAAAACE if theres a new word coming
        else if (wrapped_text) {
            wrapped_text = wrapped_text " ";
        }
        # Add the new text and remove it from the old
        wrapped_text = wrapped_text substr(text, 1, rel_pos - 1);
        if (length(text) >= rel_pos) {
            text = substr(text, rel_pos + 1);
        } else {
            text = "";
        }
    }
    return wrapped_text
}
function index_view() {
    title=$4;
    description=$5;
    wordcount=$8;
    tag_count = split($6, tags, ",");
    split($7, tag_colors, ",");
    # Top row, title part
    printf("%s %s%d  %s%s", fmt[BG color_mode], fmt[NUM color_mode], entry_index, fmt[TITLE color_mode], title);
    if (length(entry_index) + length(title) + length(wordcount) + 5 > termwidth - 2) {
        printf("[K\n  ");
    } else {
        printf("  ");
    }
    # Top row, number part
    printf("%s(%d)%s[K\n ", fmt[NUM color_mode], wordcount, fmt[BG color_mode]);
    # Tag row
    x = 0;
    for (j in tags) {
        tag_width = length(tags[j]) + 2;
        if (x > 0 && x + tag_width > termwidth - 2) {
            x = 0;
            printf("%s[K\n", fmt[BG color_mode]);
        }
        if (color_mode == TC) {
            tag_color = tag_colors[j] "m";
        } else {
            tag_color = "";
        }
        printf("%s%s %s %s ", fmt[TAG color_mode], tag_color, tags[j], fmt[BG color_mode]);
        x += tag_width + 1;
    }
    # End of the tag row
    printf("[K\n");
    # Description and hr row
    split(wrap(description, 0, 0, ""), description_rows, "\n");
    for (j in description_rows) {
        printf("  %s%s%s[K\n", fmt[DESC color_mode], description_rows[j], fmt[BG color_mode]);
    }
}
function backstory_view() {
    if (entry_index == 0 && header) {
        _header_prefix = "Backstory pages for: "
        printf("  %s%s[3m%s[K\n  %s", fmt[HEADER color_mode],
               _header_prefix, header, fmt[HEADERLINE color_mode]);
        for (ii=0; ii<length(header)+length(_header_prefix); ii++) {
            printf("▔");
        }
        printf("[K\n");
    }
    filename = $1;
    title = $2;
    revision = $3;
    metaline_wordcount = $4;
    wordcount = $5 - metaline_wordcount;
    printf("%s %s%d  %s%s", fmt[BG color_mode], fmt[NUM color_mode],
           entry_index, fmt[TITLE color_mode], title);
    printf("%s (%d)", fmt[NUM color_mode], wordcount);
    if (revision > 0) {
        printf(" %s[rev. %d]", fmt[REV color_mode], revision);
    }
    printf("%s[K\n", fmt[BG color_mode]);
}
{
    if (entry_index == 0) {
        print fmt[BG color_mode]"[K";
    } else {
        printf("%s%s  %s[K\n", fmt[BG color_mode], fmt[HR color_mode], hr);
    }
    if (view_mode == "index") {
        index_view();
    } else if (view_mode == "backstory") {
        backstory_view();
    } else {
        print "##INVALID VIEW MODE##\n" >> "/dev/stderr";
    }
    entry_index++;
}
END {
    if (entry_index > 0) {
        print fmt[BG color_mode]"[K"fmt_reset;
    }
}
