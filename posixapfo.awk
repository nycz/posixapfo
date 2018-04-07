#!/bin/awk -f
# 1 - bold
# 3 - italic
# 22 - normal color or intensity (aka not bold)
# 23 - not italic, not fraktur
# 39 - reset foreground
# [K - fill line
BEGIN {
    # Formatting
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
    split(tagfilter, tag_filter_array, ",");
    tag_token_count = tokenize(tagfilter, tag_tokens,   "", "", 0, 0);
}
function tokenize(text, tokens,    char, buf, pos, stack_depth) {
    buf = "";
    tokens[1] = " ";
    pos = 2;
    chunk_start_stack[1] = 1;
    stack_depth = 1;
    while (text) {
        char = substr(text, 1, 1);
        if (length(text) > 1) {
            text = substr(text, 2);
        } else {
            text = "";
        }
        if (char ~ /^[()|,]$/) {
            if (buf) {
                if (char == "(" && buf != "-") {
                    print "Error: Invalid starting parenthesis";
                    exit 1;
                }
                tokens[pos] = buf;
                pos++;
                buf = "";
            } else {
                t = tokens[pos-1];
                if ((t == ")" && char == "(") || (t ~ /^[(,|]$/ && char != "(")) {
                    print "Error: Invalid parentheses";
                    exit 2;
                }
            }
            if (char == "," || char == "|") {
                mode = tokens[chunk_start_stack[stack_depth]];
                if (mode == " ") {
                    tokens[chunk_start_stack[stack_depth]] = char;
                } else if (mode != char) {
                    printf("Error: mixed comparison operators: '%s' != '%s'\n", mode, char);
                    exit 3;
                }
            } else {
                tokens[pos] = char;
                pos++;
            }
            # Mode stack stuff
            if (char == "(") {
                stack_depth++;
                chunk_start_stack[stack_depth] = pos;
                tokens[pos] = " ";
                pos++;
            } else if (char == ")") {
                if (tokens[chunk_start_stack[stack_depth]] == " ") {
                    tokens[chunk_start_stack[stack_depth]] = ",";
                }
                stack_depth--;
            }
        } else {
            buf = buf char;
        }
    }
    if (buf) {
        tokens[pos] = buf;
        pos++;
    }
    if (tokens[1] == " ") {
        tokens[1] = ",";
    }
    return pos-1
}
function match_tags(tokens, token_count, tags_, pos, stack_depth) {
    stack_depth = 1
    inverse_stack[stack_depth] = 0;
    mode_stack[stack_depth] = tokens[1];
    result_stack[stack_depth] = 1;
    pos = 2;
    for (pos = 2; pos <= token_count; pos++) {
        if (tokens[pos] == "(" || tokens[pos] == "-") {
            if (tokens[pos] == "-") {
                set_inverse = 1;
                pos++;
                if (tokens[pos] != "(") {
                    printf("Error 2: only '(' can follow '-', not '%s'\n", tokens[pos]);
                    exit 6;
                }
            }
            stack_depth++;
            pos++;
            mode_stack[stack_depth] = tokens[pos];
            # Set default result, 1 for AND and 0 for OR
            if (tokens[pos] == ",") {
                result_stack[stack_depth] = 1;
            } else if (tokens[pos] == "|") {
                result_stack[stack_depth] = 0;
            } else {
                printf("Error 1: invalid mode: '%s'\n", tokens[pos]);
                exit 5;
            }
            inverse_stack[stack_depth] = inverse_stack[stack_depth-1];
            if (set_inverse) {
                inverse_stack[stack_depth] = !inverse_stack[stack_depth];
            }
        } else if (tokens[pos] == ")") {
            result = result_stack[stack_depth];
            if (inverse_stack[stack_depth]) {
                result = !result;
            }
            stack_depth--;
            if (mode_stack[stack_depth] == ",") {
                result_stack[stack_depth] = result_stack[stack_depth] && result;
            } else if (mode_stack[stack_depth] == "|") {
                result_stack[stack_depth] = result_stack[stack_depth] || result;
            } else {
                printf("Error 3: invalid mode: '%s'\n", mode_stack[stack_depth]);
                exit 5;
            }
        } else {
            tag = tokens[pos];
            negative = tag ~ /^-/;
            if (negative) {
                tag = substr(tag, 2);
            }
            in_tag_list = 0;
            for (i in tags) {
                if (tags[i] == tag) {
                    in_tag_list = 1;
                    break;
                }
            }
            result = ((in_tag_list && !negative) || (!in_tag_list && negative));
            if (mode_stack[stack_depth] == ",") {
                result_stack[stack_depth] = result_stack[stack_depth] && result;
            } else if (mode_stack[stack_depth] == "|") {
                result_stack[stack_depth] = result_stack[stack_depth] || result;
            } else {
                printf("Error 4: invalid mode: '%s'\n", mode_stack[stack_depth]);
                exit 5;
            }
        }
    }
    return result_stack[1];
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
    if (match_tags(tag_tokens, tag_token_count, tags, 0, 0)) { #_parse(tree2, tags, "", 1, 1)) {
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
}
END {
    if (entry_index > 0) {
        print fmt_bg"[K"fmt_reset;
    }
}
