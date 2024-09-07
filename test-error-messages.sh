#!/bin/bash

function fail() {
    printf 'FAIL: %s\n' "$1"
    exit 1
}

function goku() {
    echo Testing: ./zig-out/bin/goku "$@"
    ./zig-out/bin/goku "$@" >/dev/null 2>&1
}

zig build -Doptimize=ReleaseSafe
# shellcheck disable=SC2181
[[ $? -eq 0 ]] || fail "Could not compile"

goku
[[ $? -eq 1 ]] || fail "Expected a failure exit code"

goku site -o build
# shellcheck disable=SC2181
[[ $? -eq 0 ]] || fail "Build site with relative paths"

goku "$PWD/site" -o "$PWD/build"
[[ $? -eq 0 ]] || fail "Build site using absolute paths"
