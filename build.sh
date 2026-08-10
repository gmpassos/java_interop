#!/bin/sh
# Compiles the Java sources under java/ into build/java_interop.jar.
#
# The jar is a build artefact (build/ is gitignored); every entry point that
# needs it -- run.sh, the tests, the example -- builds it on demand.
set -eu

cd "$(dirname "$0")"
. ./java_home.sh

echo "JAVA_HOME=$JAVA_HOME"

rm -rf build/classes
mkdir -p build/classes

find java -name '*.java' -print0 \
  | xargs -0 "$JAVA_HOME/bin/javac" -Xlint:all -d build/classes

"$JAVA_HOME/bin/jar" --create --file build/java_interop.jar -C build/classes .

echo "built $(pwd)/build/java_interop.jar"
