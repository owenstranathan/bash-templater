#!/bin/bash
#
# Very simple templating system that replaces {{VAR}} by the value of $VAR.
# Supports default values by writting {{VAR=value}} in the template.
#
# Copyright (c) 2017 Sébastien Lavoie
# Copyright (c) 2017 Johan Haleby
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# See: https://github.com/johanhaleby/bash-templater
# Version: https://github.com/johanhaleby/bash-templater/commit/5ac655d554238ac70b08ee4361d699ea9954c941

# Replaces all {{VAR}} by the $VAR value in a template file and outputs it

readonly PROGNAME=$(basename $0)

case "$OSTYPE" in
    *darwin*)
        BSD=1
        ;;
    *linux*)
        GNU=1
        ;;
esac

usage="${PROGNAME} [-h] [-d] [-f] [-s] [-o] [-r] [-q] --

where:
    -h, --help
        Show this help text
    -p, --print
        Don't do anything, just print the result of the variable expansion(s)
    -f, --file
        Specify a file to read variables from
    -s, --silent
        Don't print warning messages (for example if no variables are found)
    -d, --delimiter
        Specify a delimiter to separate output from multiple files (defaults to '\n---\n')
    -o --output
        Specify to write the output to files in the given directory instead of stdout
    -r --recursive
        Searches recursively for files in the template directory
    -q --quiet
        Don't output anything but errors (for use with -o)

examples:
    VAR1=Something VAR2=1.2.3 ${PROGNAME} test.txt
    ${PROGNAME} test.txt -f my-variables.txt
    ${PROGNAME} test.txt -f my-variables.txt > new-test.txt"

if [ $# -eq 0 ]; then
  echo "$usage"
  exit 1
fi


if [[ ! -f "${1}" ]] && [[ ! -d "${1}" ]]; then
    echo "You need to specify a template file or directory" >&2
    echo "$usage"
    exit 1
fi

function load_env_file() {
    local env_file="$1"
    if [[ -f "$env_file" ]]; then
        local variables
        if [[ "$BSD" ]]; then
            variables=$(grep -v '^#' "$env_file" | grep -v '^\w*$' | xargs -0)
        else
            variables=$(grep -v '^#' "$env_file" | grep -v '^\w*$' | xargs -d '\n')
        fi
        for var in $variables; do
            export "${var?}"
        done
    fi
}

function errcho() {
    echo "$@" 1>&2
}

function parse_args() {
    template_path="${1}"
    delimiter="\n---\n"
    print_only="false"
    silent="false"

    if [ "$#" -ne 0 ]; then
        while [ "$#" -gt 0 ]
        do
            case "$1" in
                -h|--help)
                    echo "$usage"
                    exit 0
                    ;;
                -p|--print)
                    print_only="true"
                    ;;
                -f|--file)
                    load_env_file "$2"
                    ;;
                -s|--silent)
                    silent="true"
                    ;;
                -d|--delimiter)
                    delimiter="$2"
                    ;;
                -o|--output)
                    output="$2"
                    ;;
                -r|--recursive)
                    recursive="true"
                    ;;
                -q|--quiet)
                    quiet="true"
                    ;;
                --)
                    break
                    ;;
                -*)
                    echo "Invalid option '$1'. Use --help to see the valid options" >&2
                    exit 1
                    ;;
                # an option argument, continue
                *)  ;;
            esac
            shift
        done
    fi

}

##
# Escape custom characters in a string
# Example: escape "ab'\c" '\' "'"   ===>  ab\'\\c
#
function escape_chars() {
    local content="${1}"
    shift
    for char in "$@"; do
        content="${content//${char}/\\${char}}"
    done
    echo "${content}"
}

function echo_var() {
    local var="${1}"
    local content="${2}"
    local escaped="$(escape_chars "${content}" "\\" '"')"
    echo "${var}=\"${escaped}\""
}

function var_value() {
    var="${1}"
    eval echo \$"${var}"
}

function perl_match() {
    perl - "$TEMPLATE_CONTENT" $1 <<'EOF'
    my $string = shift;
    my $index = shift;
    my $regex = qr/\s*{%\s*if\s*(.*?(?=%}))%}(.*?(?={%))(\s*{%\s*else\s*%})?(.*?(?={%))\s*{%\s*endif\s*%}/sp;
    my @matches = ( $string =~ /$regex/ );
    if (! @matches) {
        exit 1;
    }
    if ( $index ==   -1 ){
        # if ($string =~ /$regex/ ) {
        print "${^MATCH}";
        # }
        # print "${^PREMATCH}";
        # print "${^POSTMATCH}";
    }
    else{
        print "@matches[$index]";
    }
EOF
}

function replace_ifs() {
    while perl_match -1 /dev/null 2>&1; do
        match=$(perl_match -1) > /dev/null
        condition=$(perl_match 0) > /dev/null
        case_true=$(perl_match 1) > /dev/null
        case_false=$(perl_match 3) > /dev/null
        if eval "$condition"; then
            replace="$case_true"
        else
            replace="$case_false"
        fi
        TEMPLATE_CONTENT="${TEMPLATE_CONTENT/"$match"/$replace}"
    done
}

function render(){
    vars=$(echo "$TEMPLATE_CONTENT" | grep -oE '\{\{[[:space:]]*[A-Za-z0-9_]+[[:space:]]*\}\}' | sort | uniq | sed -e 's/^{{//' -e 's/}}$//')

    if [[ -z "$vars" ]]; then
        if [[ "$silent" == "false" ]]; then
            echo "Warning: No variable was found in $template, syntax is {{VAR}}" >&2
        fi
        return 0
    fi

    declare -a replaces
    replaces=()

    # Reads default values defined as {{VAR=value}} and delete those lines
    # There are evaluated, so you can do {{PATH=$HOME}} or {{PATH=`pwd`}}
    # You can even reference variables defined in the template before
    defaults=$(echo "$TEMPLATE_CONTENT" | grep -oE '^\{\{[A-Za-z0-9_]+=.+\}\}$' | sed -e 's/^{{//' -e 's/}}$//')
    IFS=$'\n'
    for default in $defaults; do
        var=$(echo "${default}" | grep -oE "^[A-Za-z0-9_]+")
        current="$(var_value "${var}")"

        # Replace only if var is not set
        if [[ -n "$current" ]]; then
            eval "$(echo_var "${var}" "${current}")"
        else
            eval "${default}"
        fi

        # remove define line
        replaces+=("-e")
        replaces+=("/^{{${var}=/d")
        vars="${vars} ${var}"
    done

    vars="$(echo "${vars}" | tr " " "\n" | sort | uniq)"

    if [[ "$2" = "-h" ]]; then
        for var in $vars; do
            value="$(var_value "${var}")"
            echo_var "${var}" "${value}"
        done
        exit 0
    fi

    if [[ "$print_only" == "true" ]]; then
    for var in $vars; do
        value=$(var_value "$var")
        echo "$var=$value"
    done
    exit 0
    fi

    # Replace all {{VAR}} by $VAR value

    for var in $vars; do
        value="$(var_value "${var}")"
        if [[ -z "$value" ]] && [[ "$silent" == "false" ]]; then
            echo "Warning: $var is not defined and no default is set, replacing by empty" >&2
        fi

        # Escape slashes
        value="$(escape_chars "${value}" "\\" '/' ' ')";
        replaces+=("-e")
        replaces+=("s/{{[[:space:]]*${var}[[:space:]]*}}/${value}/g")
    done
    TEMPLATE_CONTENT="$(echo "$TEMPLATE_CONTENT" | sed "${replaces[@]}")"
}

function main() {
    [[ $TRACE ]] && set -x
    local template_path
    template_path="$1"
    TEMPLATE_CONTENT="$(cat "$1")"
    if [[ -f ".env" ]]; then
        load_env_file ".env"
    fi
    replace_ifs > /dev/null 2>&1
    render
    if [[ -z "$quiet" ]]; then
        echo "$TEMPLATE_CONTENT"
    fi
    if [[ ! -z "$output" ]]; then
        mkdir -p "$(dirname "$output/$template_path")"
        echo "$TEMPLATE_CONTENT" >> "$output/$template_path"
    fi
}


function template_dir() {
        shopt -s globstar nullglob 2>/dev/null
        templates=( "$1/"* )
        len=${#templates[@]}
        len=$((len-1))
        needs_delim="false"
        for i in $(seq 0 $len); do
            if [[ -d "${templates[i]}" ]] && [[ -z "$recursive" ]]; then
                needs_delim="false"
                continue;
            fi
            if [[ "$needs_delim" == "true" ]] && [[ -z "$output" ]]; then
                echo -e "$delimiter"
            fi
            if [[ -f "${templates[i]}" ]]; then
                main "${templates[i]}"
            elif [[ -d "${templates[i]}" ]] && [[ ! -z "$recursive" ]] && [[ "$recursive" == "true" ]]; then
                template_dir "${templates[i]}"
            fi
            if [ $i -lt $len ] && [ -z "$output" ]; then
                needs_delim="true";
            fi
        done
}


parse_args "$@"
if [[ -f "$template_path" ]]; then
    main "$template_path"
elif [[ -d "$template_path" ]]; then
    template_dir "$template_path"
fi
