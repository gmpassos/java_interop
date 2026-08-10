#!/bin/sh
# Builds every jar in the repository, by delegating to the project that owns it.
#
# There is no shared jar any more: the test fixtures belong to the test suite
# and the greeter's class belongs to the example that calls it, so each builds
# its own next to its own sources. This script is the convenience that runs both.
set -eu

cd "$(dirname "$0")"

./test/build.sh
./example/greeter/build.sh
