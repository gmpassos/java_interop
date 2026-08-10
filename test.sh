#!/bin/sh
# Builds the fixtures jar if needed, then runs the Dart test suite.
#
# The suite needs JAVA_HOME exported so the tests can locate libjvm; sourcing
# java_home.sh here is what makes `./test.sh` work with no shell setup.
set -eu

cd "$(dirname "$0")"
. ./java_home.sh

[ -f build/java_interop.jar ] || ./build.sh

dart pub get --offline >/dev/null 2>&1 || dart pub get
exec dart test "$@"
