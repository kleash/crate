#!/bin/bash
# Runs the Swift Testing suite. Command Line Tools have no XCTest and keep Testing.framework
# outside the default search paths, so point the compiler, linker and rpath at it.
# Extra arguments go to `swift test` (e.g. ./test.sh --filter linksSystemLibarchive).
set -euo pipefail
cd "$(dirname "$0")"

version=$(swift --version 2>&1) || true
if [[ ! $version =~ Swift\ version\ ([0-9]+)[0-9.]* ]] || (( BASH_REMATCH[1] < 6 )); then
    echo "The tests use Swift Testing, which needs Swift 6 or later (this Mac has ${BASH_REMATCH[0]:-no Swift})." >&2
    echo "The app itself builds with Swift 5.9 or later: ./build.sh" >&2
    exit 1
fi
clt=$(xcode-select -p)
fw=$clt/Library/Developer/Frameworks
il=$clt/Library/Developer/usr/lib
exec swift test \
    -Xswiftc -F -Xswiftc "$fw" \
    -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$il" \
    "$@"
