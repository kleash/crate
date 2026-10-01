#!/bin/bash
# Runs the Swift Testing suite. Command Line Tools have no XCTest and keep Testing.framework
# outside the default search paths, so point the compiler, linker and rpath at it.
# Extra arguments go to `swift test` (e.g. ./test.sh --filter linksSystemLibarchive).
set -euo pipefail
cd "$(dirname "$0")"

clt=$(xcode-select -p)
fw=$clt/Library/Developer/Frameworks
il=$clt/Library/Developer/usr/lib
exec swift test \
    -Xswiftc -F -Xswiftc "$fw" \
    -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$il" \
    "$@"
