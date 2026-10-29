#!/bin/bash
# Proves the packaged app does not depend on the build machine: copies YACW.app to a temp folder, hides .build, and checks
# that the resource bundle loads from Contents/Resources. Usage: ./scripts/check-bundle.sh  (run after bundle.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d YACW.app ] || { echo "run ./scripts/bundle.sh first"; exit 1; }
TMP="$(mktemp -d)"
cp -R YACW.app "$TMP/"
restore() { [ -d .build.hidden ] && mv .build.hidden .build; rm -rf "$TMP"; }
trap restore EXIT
mv .build .build.hidden
"$TMP/YACW.app/Contents/MacOS/YACW" --check-resources
