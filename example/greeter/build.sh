#!/bin/sh
# Compiles this example's Java source into build/greeter.jar, beside it.
#
# Everything the greeter needs lives in this directory: the Java class it calls,
# the jar built from it, the JDK discovery, and the Dart program that loads it.
set -eu

cd "$(dirname "$0")"
. ./java_home.sh

echo "JAVA_HOME=$JAVA_HOME"

rm -rf build/classes
mkdir -p build/classes

find java -name '*.java' -print0 \
  | xargs -0 "$JAVA_HOME/bin/javac" -Xlint:all -d build/classes

"$JAVA_HOME/bin/jar" --create --file build/greeter.jar -C build/classes .

echo "built $(pwd)/build/greeter.jar"
