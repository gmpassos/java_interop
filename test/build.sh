#!/bin/sh
# Compiles the test fixtures under test/java/ into test/build/fixtures.jar.
#
# Owned by the test suite and used by nothing else: the jar is a build artefact
# (test/build/ is gitignored), and test.sh rebuilds it on demand.
set -eu

cd "$(dirname "$0")"
. ./java_home.sh

echo "JAVA_HOME=$JAVA_HOME"

rm -rf build/classes
mkdir -p build/classes

find java -name '*.java' -print0 \
  | xargs -0 "$JAVA_HOME/bin/javac" -Xlint:all -d build/classes

"$JAVA_HOME/bin/jar" --create --file build/fixtures.jar -C build/classes .

echo "built $(pwd)/build/fixtures.jar"
