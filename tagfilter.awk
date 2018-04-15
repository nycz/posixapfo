#!/bin/awk -f
#
# Inputs: (provide with -v)
#   tag_filter - sanitized tag filter with no SPAAAACE around (),|
#
# stdin should be a list of tab-seperated values, see the main part
# of this program for details on individual values
#
BEGIN {
    # Init stuff
    split(tag_filter, tag_filter_array, ",");
    # Init tag macros
    split(raw_tag_macros, tag_macro_array, "\n");
    for (tag_macro_array_i in tag_macro_array) {
        split(tag_macro_array[tag_macro_array_i], tag_macro_pair, "\t");
        tag_macros["@"tag_macro_pair[1]] = tag_macro_pair[2];
    }
    # Generate the tokens
    tag_token_count = tokenize(tag_filter, tag_tokens,   "", "", 0, 0);
}
function tokenize(text, tokens,    char, buf, pos, depth) {
    buf = "";
    tokens[1] = " ";
    pos = 2;
    chunk_starts[1] = 1;
    depth = 1;
    while (1) {
        # Make the linter happy
        if (length(text) > 1) {
            char = substr(text, 1, 1);
            text = substr(text, 2);
        } else if (length(text) > 0) {
            char = substr(text, 1, 1);
            text = "";
        } else {
            char = "";
            text = "";
        }
        # Special stuff happens to special characters!
        if (char ~ /^[()|,]?$/) {
            if (buf) {
                # Add the buffer to the token list
                if (char == "(" && buf != "-") {
                    print "Error: Invalid starting parenthesis" > "/dev/stderr";
                    exit 1;
                }
                # Expand macros
                if (buf ~ /^-?@/) {
                    # Add - if negative
                    if (buf ~ /^-/) {
                        tokens[pos] = "-";
                        pos++;
                        buf = substr(buf, 2);
                    }
                    # Add the macro to the text
                    text = "(" tag_macros[buf] ")" char text;
                    buf = "";
                } else {
                    tokens[pos] = buf;
                    pos++;
                    buf = "";
                }
            } else {
                # Some special characters shouldn't be following others
                t = tokens[pos-1];
                if ((t == ")" && char == "(") || (t ~ /^[(,|]$/ && char != "(")) {
                    print "Error: Invalid parentheses" > "/dev/stderr";
                    exit 2;
                }
            }
            if (char == "," || char == "|") {
                # Polish notation for a polished individual
                mode = tokens[chunk_starts[depth]];
                if (mode == " ") {
                    tokens[chunk_starts[depth]] = char;
                } else if (mode != char) {
                    printf("Error: mixed comparison operators: '%s' != '%s'\n", mode, char) > "/dev/stderr";
                    exit 3;
                }
            } else if (char != "") {
                # All the other special chars should be on their merry way
                tokens[pos] = char;
                pos++;
            }
            # Mode stack stuff
            if (char == "(") {
                depth++;
                chunk_starts[depth] = pos;
                tokens[pos] = " ";
                pos++;
            } else if (char == ")") {
                if (tokens[chunk_starts[depth]] == " ") {
                    tokens[chunk_starts[depth]] = ",";
                }
                depth--;
            }
        } else {
            # If the character isn't special, just append it
            buf = buf char;
        }
        # Poor folk's do ... until()
        if (buf == "" && text == "") {
            break;
        }
    }
    # If there's only one token, throw your AND in the air cause we just don't care
    if (tokens[1] == " ") {
        tokens[1] = ",";
    }
    return pos-1
}
function match_tags(tokens, token_count, tags_, pos, depth) {
    depth = 1
    inverse_stack[depth] = 0;
    mode_stack[depth] = tokens[1];
    result_stack[depth] = 1;
    pos = 2;
    for (pos = 2; pos <= token_count; pos++) {
        if (tokens[pos] == "(" || tokens[pos] == "-") {
            if (tokens[pos] == "-") {
                set_inverse = 1;
                pos++;
                if (tokens[pos] != "(") {
                    printf("Error 2: only '(' can follow '-', not '%s'\n", tokens[pos]) > "/dev/stderr";
                    exit 6;
                }
            }
            depth++;
            pos++;
            mode_stack[depth] = tokens[pos];
            # Set default result, 1 for AND and 0 for OR
            if (tokens[pos] == "," || tokens[pos] == " ") {
                result_stack[depth] = 1;
            } else if (tokens[pos] == "|") {
                result_stack[depth] = 0;
            } else {
                printf("Error 1: invalid mode: '%s'\n", tokens[pos]) > "/dev/stderr";
                exit 5;
            }
            inverse_stack[depth] = inverse_stack[depth-1];
            if (set_inverse) {
                inverse_stack[depth] = !inverse_stack[depth];
            }
        } else if (tokens[pos] == ")") {
            result = result_stack[depth];
            if (inverse_stack[depth]) {
                result = !result;
            }
            depth--;
            if (mode_stack[depth] == ",") {
                result_stack[depth] = result_stack[depth] && result;
            } else if (mode_stack[depth] == "|") {
                result_stack[depth] = result_stack[depth] || result;
            } else {
                printf("Error 3: invalid mode: '%s'\n", mode_stack[depth]) > "/dev/stderr";
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
            if (mode_stack[depth] == ",") {
                result_stack[depth] = result_stack[depth] && result;
            } else if (mode_stack[depth] == "|") {
                result_stack[depth] = result_stack[depth] || result;
            } else {
                printf("Error 4: invalid mode: '%s'\n", mode_stack[depth]) > "/dev/stderr";
                exit 5;
            }
        }
    }
    return result_stack[1];
}
{
    tag_count = split($6, tags, ",");
    if (match_tags(tag_tokens, tag_token_count, tags, 0, 0)) {
        print $0;
    }
}
