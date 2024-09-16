#!/bin/bash

function fail() {
    printf 'FAIL: %s\n' "$1"
    exit 1
}

function goku() {
    echo Testing: ./zig-out/bin/goku "$@"
    ./zig-out/bin/goku "$@" >/dev/null 2>&1
}

if ! zig build -Doptimize=ReleaseSafe; then
    fail "Could not compile"
fi

if goku; then
    fail "Expected a failure exit code"
fi


if ! goku site -o build; then
    fail "Build site with relative paths";
fi

if ! goku "$PWD/site" -o "$PWD/build"; then
    fail "Build site using absolute paths"
fi