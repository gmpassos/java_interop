#!/bin/sh
# Builds the test fixtures jar if needed, then runs the Dart test suite.
#
# The suite needs JAVA_HOME exported so the tests can locate libjvm; sourcing
# the suite's own java_home.sh is what makes `./test.sh` work with no shell
# setup.
set -eu

cd "$(dirname "$0")"
. ./test/java_home.sh

[ -f test/build/fixtures.jar ] || ./test/build.sh

dart pub get --offline >/dev/null 2>&1 || dart pub get
exec dart test "$@"
