#!/bin/sh
# Builds the jar if needed, then runs the Dart example against it.
set -eu

cd "$(dirname "$0")"
. ./java_home.sh

[ -f build/java_interop.jar ] || ./build.sh

dart pub get --offline >/dev/null 2>&1 || dart pub get
exec dart run bin/greeter_example.dart "$@"
