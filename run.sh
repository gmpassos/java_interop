#!/bin/sh
# Builds the jar if needed, then runs the greeter example against it.
#
# The greeter lives in example/greeter/, which is its own Dart project with a
# path dependency on this one, so it needs its own `pub get` before it can run.
set -eu

cd "$(dirname "$0")"
. ./java_home.sh

[ -f build/java_interop.jar ] || ./build.sh

JAR="$(pwd)/build/java_interop.jar"

cd example/greeter
dart pub get --offline >/dev/null 2>&1 || dart pub get

if [ "$#" -gt 0 ]; then
  exec dart run bin/greeter_example.dart "$@"
fi
exec dart run bin/greeter_example.dart "$JAR"
