#!/bin/bash

TESTING_DIR="$(dirname "$BASH_SOURCE")"
PACKAGE_DIR="$(dirname "$TESTING_DIR")"

function check() {
    if [[ $1 -eq 0 ]]; then
        echo OK
    else
        echo Differences found
        exit 1
    fi
}

function test_simple(){
    (
        cd "$PACKAGE_DIR/examples/simple/"
        diff -u <(bash ../../templater.sh nginx.yaml.tmpl) nginx.yaml
        return $?
    )
}

function test_defaults(){
    (
        cd "$PACKAGE_DIR/examples/defaults/"
        diff -u <(USER=nobody DOMAIN=example.com ../../templater.sh vhost-php.tpl.conf) vhost-php.conf
        return $?
    )

}

function test_templates_dir(){
    (
        cd "$PACKAGE_DIR/examples/templates-dir"
        diff -u <(bash ../../templater.sh templates -f variables.txt) render.yaml
        return $?
    )
}

function test_recursive(){
    (
        cd "$PACKAGE_DIR/examples/templates-dir"
        diff -u <(bash ../../templater.sh templates -f variables.txt -r) recursive_render.yaml
        return $?
    )
}

function test_output_recursive(){
    (
        cd "$PACKAGE_DIR/examples/templates-dir"
        bash ../../templater.sh templates -f variables.txt -r -q -o ./temp
        diff -r temp/ render/
        ret="$?"
        rm -rf ./temp
        return $ret
    )
}

function test_print_only(){
    (
        cd "$PACKAGE_DIR/examples/simple"
        diff -u <(bash ../../templater.sh nginx.yaml.tmpl -p) .env
        return $?
    )
}
function test_silent(){

    mkdir -p "test_silent_temp"
    trap "rm -rf test_silent_temp" INT TERM EXIT ERR
    (
        cd test_silent_temp
        echo "{{TEST_SILENT_NOT_SET}} is not set" > test.tmpl
        diff <(bash "$PACKAGE_DIR/templater.sh" test.tmpl -s) <(echo " is not set")
        return $?
    )
}

function test_conditionals(){
    (
        cd "$PACKAGE_DIR/examples/conditionals"
        diff -u <(bash ../../templater.sh conditions.tmpl.yaml -s) render.yaml
        return $?
    )
}

# test_simple
# check $?
# test_defaults
# check $?
# test_templates_dir
# check $?
# test_print_only
# check $?
# test_silent
# check $?
# test_silent
# check $?

