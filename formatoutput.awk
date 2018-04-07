#!/bin/awk -f
# 
# Inputs: (provide with -v)
#   full_hr - a string to be used as horizontal line between entries
#   termwidth - the width of the terminal
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
    # 1 - bold
    # 3 - italic
    # 22 - normal color or intensity (aka not bold)
    # 23 - not italic, not fraktur
    # 39 - reset foreground
    # [K - fill line
    hr = substr(full_hr, 5);
    fmt_reset = "[0m";
    fmt_bg = "[39;22;23;48;2;34;51;51m";
    fmt_num = "[22;38;2;102;119;119;3m";
    fmt_title = "[23;38;2;204;221;221;1m";
    fmt_tag = "[22;23;38;2;0;17;17;48;2;";
    fmt_desc = "[22;23;38;2;136;153;153m";
    fmt_hr = "[22;23;38;2;0;0;0m";
    # Init stuff
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
        wrapped_text = wrapped_text substr(text, 1, rel_pos - 1)
        if (length(text) >= rel_pos) {
            text = substr(text, rel_pos + 1);
        } else {
            text = "";
        }
    }
    return wrapped_text
}
{
    title=$4;
    description=$5;
    wordcount=$8;
    tag_count = split($6, tags, ",");
    split($7, tag_colors, ",");
    if (entry_index == 0) {
        print fmt_bg"[K";
    } else {
        printf("%s%s  %s[K\n", fmt_bg, fmt_hr, hr);
    }
    # Top row
    printf("%s %s%d  %s%s  %s(%d)%s[K\n ",
           fmt_bg, fmt_num, entry_index, fmt_title, title, fmt_num, wordcount, fmt_bg);
    # Tag row
    for (j in tags) {
        printf("%s%sm %s %s ", fmt_tag, tag_colors[j], tags[j], fmt_bg);
    }
    # End of the tag row
    printf("[K\n");
    # Description and hr row
    split(wrap(description, 0, 0, ""), description_rows, "\n");
    for (j in description_rows) {
        printf("  %s%s%s[K\n", fmt_desc, description_rows[j], fmt_bg);
    }
    entry_index++;
}
END {
    if (entry_index > 0) {
        print fmt_bg"[K"fmt_reset;
    }
}
