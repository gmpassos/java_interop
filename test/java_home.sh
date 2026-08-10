#!/bin/sh
# Sourced by test/build.sh and test.sh. Exports JAVA_HOME if it is not set.
#
# The test suite owns its JDK discovery, as it owns its Java sources and its
# jar, so nothing under test/ reaches outside it to build or run.
#
# Homebrew's openjdk kegs are keg-only, so /usr/libexec/java_home does not see
# them unless they have been symlinked into /Library/Java/JavaVirtualMachines.
# Check the Homebrew prefixes first, then fall back to the system lookup.
#
# Keep the search order in step with `searchLibjvm` in lib/src/java_home.dart
# and with example/greeter/java_home.sh, so every entry point agrees on which
# JDK is in use.

if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in \
    /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  do
    if [ -x "$candidate/bin/javac" ]; then
      JAVA_HOME="$candidate"
      break
    fi
  done

  if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ] \
     && /usr/libexec/java_home >/dev/null 2>&1; then
    JAVA_HOME="$(/usr/libexec/java_home)"
  fi

  if [ -z "${JAVA_HOME:-}" ]; then
    echo "No JDK found. Set JAVA_HOME to a JDK (not a JRE), e.g." >&2
    echo '  export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"' >&2
    exit 1
  fi

  export JAVA_HOME
fi

if [ ! -x "$JAVA_HOME/bin/javac" ]; then
  echo "JAVA_HOME=$JAVA_HOME has no bin/javac (a JRE, not a JDK?)." >&2
  exit 1
fi
