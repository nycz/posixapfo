#!/bin/sh

fatal_error() {
    # $1 = message, $2 = exit code (optional)
    error_prefix='Error: '
    printf '%s%s\n' "$error_prefix" "$1" >&2
    exit "${2-1}"  # default to exit code 1
}

# Make sure we're in the right directory
cd "$(dirname "$0")" || fatal_error 'cd failed'

# Init paths and files
test_dir='test_data'
cache_dir="$test_dir/cache"
settings_file="$test_dir/settings.json"
entries_dir="$test_dir/entries"
wanted_result_file="$test_dir/temp_wanted_result"
test_result_file="$test_dir/temp_test_result"

# Default settings file
printf '{"path": "%s"}\n' "$entries_dir" > "$settings_file"


# Main comparison function
check_test_result() {
    test -z "$test_prefix" && fatal_error 'missing test_prefix'
    test -z "$local_test_count"\
        && fatal_error "missing local_test_count, in prefix '${test_prefix}'"
    case "$local_test_count" in
        *[!0-9]*) fatal_error "local_test_count is not a number: '${local_test_count}', in prefix '${test_prefix}" ;;
    esac
    # Increase total test count and the local test id
    test_count=$((test_count + 1))
    local_test_count=$((local_test_count + 1))
    # TODO: possibly use comm here too? idk
    diff "$wanted_result_file" "$test_result_file" > '/dev/null'
    if test ! "$?" -eq '0' ; then
        # Print info about the failed test
        printf '[1;31m!! Test failed: <%s.%d>[0m\n' "$test_prefix" "$local_test_count"
        # Show the added lines (aka results that should not have been included)
        _added_lines="$(comm -13 "$wanted_result_file" "$test_result_file" | sed 's/^/>>  /g')"
        test -n "$_added_lines" && printf '[1mExtra lines:[0m\n%s\n' "$_added_lines"
        # Show the removed lines (aka result that should have been included)
        _removed_lines="$(comm -23 "$wanted_result_file" "$test_result_file" | sed 's/^/<<  /g')"
        test -n "$_removed_lines" && printf '[1mMissing lines:[0m\n%s\n' "$_removed_lines"
        printf '\n'
    else
        test_succeeded=$((test_succeeded + 1))
    fi
    test -f "${wanted_result_file}" && rm "${wanted_result_file}"
    test -f "${test_result_file}" && rm "${test_result_file}"
}


# Individual tests starts below here

# Example test structure:
#    run_foobar_test() {
#        foo_stuff="$(dostufmaybe "$2")"
#        get_some_test_lines "$1" "$foo_stuff" > "$test_result_file"
#        generate_the_correct_lines > "$wanted_result_file"
#        # This is the important line! This will do some comparison magic.
#        check_test_result
#    }
#    test_foobar() {
#        test_prefix='foobar'
#        local_test_count=0
#        run_some_test 'argument' 'maybe test data'
#        run_some_test 'stuff' 'more test data'
#        # ... etc
#        unset test_prefix
#        unset local_test_count
#    }
#
# And then add test_foobar to the lines between init tests and print report


run_tag_filter_test() {
    entries="$1"
    tag_filter="$2"
    # A grep-y string with the prefixes for the lines we want
    target_entries="$3"
    printf '%s\n' "$entries"\
        | awk -F"	" -v tag_filter="$tag_filter" -f tagfilter.awk\
        > "$test_result_file"
    printf '%s\n' "$entries"\
        | grep -E "^(${target_entries})"\
        > "$wanted_result_file"
    check_test_result
}

test_tag_filters() {
    entries="$(printf \
'1\t_\t_\t_\t_\ttag1,tag 22,tag B
2\t_\t_\t_\t_\ttag 22,tag B
3\t_\t_\t_\t_\ttag1,tag B
4\t_\t_\t_\t_\ttag1,tag 22
5\t_\t_\t_\t_\ttag11,111111
6\t_\t_\t_\t_\t
7\t_\t_\t_\t_\ttag B,another')"
    test_prefix='tagfilter'
    local_test_count=0
    run_tag_filter_test "$entries" 'tag1,tag 22' '1|4'
    run_tag_filter_test "$entries" 'tag1|tag 22' '1|2|3|4'
    run_tag_filter_test "$entries" '' '.*'
    run_tag_filter_test "$entries" 'tag B' '1|2|3|7'
    run_tag_filter_test "$entries" 'tag11|(another,tag B)' '5|7'
    run_tag_filter_test "$entries" '-tag 22' '3|5|6|7'
    run_tag_filter_test "$entries" '-tag 22,(111111|another)' '5|7'
    run_tag_filter_test "$entries" '-tag1,-nonexistant' '2|5|6|7'
    run_tag_filter_test "$entries" '(nonexistant|nope),nah' 'X'
    unset test_prefix
    unset local_test_count
}

# Init tests
test_count=0
test_succeeded=0

# Run the tests
test_tag_filters

# Print report
if test "$test_count" -eq "$test_succeeded" ; then
    printf '[1;32mAll %d tests succeeded.[0m\n' "$test_count"
elif test "$test_count" -eq '0' ; then
    printf '[1;31mAll %d tests failed.[0m\n' "$test_count"
else
    printf '[1;33m%d/%d tests succeeded.[0m\n' "$test_succeeded" "$test_count"
fi
