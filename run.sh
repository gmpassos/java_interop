#!/bin/sh
# Builds the greeter's jar if needed, then runs the greeter example.
#
# example/greeter/ is its own Dart project with its own Java source, so both the
# build and the run happen in there; this script is just the shortcut from the
# repository root.
set -eu

cd "$(dirname "$0")/example/greeter"
. ./java_home.sh

[ -f build/greeter.jar ] || ./build.sh

dart pub get --offline >/dev/null 2>&1 || dart pub get
exec dart run bin/greeter_example.dart "$@"
