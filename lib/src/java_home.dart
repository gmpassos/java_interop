/// Locating a JDK's shared JVM library.
///
/// The Invocation API lives in `libjvm.dylib` / `libjvm.so` / `jvm.dll`, which
/// ships inside a JDK rather than on the default loader path, so it has to be
/// found before anything else can happen.
library;

import 'dart:io';

import 'errors.dart';

/// Where [defaultLibjvmPath] looked, in order, and what it found.
///
/// Exposed so a failure can explain itself: "no JDK" and "JAVA_HOME points at a
/// JRE without libjvm" are different problems with different fixes.
class LibjvmSearch {
  LibjvmSearch(this.candidates, this.resolved);

  /// Every path that was considered, in the order tried.
  final List<String> candidates;

  /// The first candidate that exists, or `null` when none did.
  final String? resolved;

  bool get found => resolved != null;
}

/// The platform-specific location of `libjvm` under a JDK home.
String libjvmUnder(String javaHome) {
  final home = javaHome.endsWith(Platform.pathSeparator)
      ? javaHome.substring(0, javaHome.length - 1)
      : javaHome;

  if (Platform.isWindows) return '$home\\bin\\server\\jvm.dll';
  if (Platform.isMacOS) return '$home/lib/server/libjvm.dylib';
  return '$home/lib/server/libjvm.so';
}

/// Searches for `libjvm` without throwing, reporting every candidate tried.
///
/// Order: `JAVA_HOME`, then platform-specific fallbacks — `/usr/libexec/
/// java_home` and the Homebrew `openjdk` kegs on macOS (which are keg-only, so
/// the system lookup does not see them), and the usual distribution paths on
/// Linux.
LibjvmSearch searchLibjvm({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final candidates = <String>[];

  void consider(String? javaHome) {
    if (javaHome == null || javaHome.isEmpty) return;
    final candidate = libjvmUnder(javaHome);
    if (!candidates.contains(candidate)) candidates.add(candidate);
  }

  consider(env['JAVA_HOME']);

  if (Platform.isMacOS) {
    consider(_runOrNull('/usr/libexec/java_home', const []));
    for (final keg in const [
      '/opt/homebrew/opt/openjdk',
      '/opt/homebrew/opt/openjdk@21',
      '/opt/homebrew/opt/openjdk@17',
      '/usr/local/opt/openjdk',
      '/usr/local/opt/openjdk@21',
      '/usr/local/opt/openjdk@17',
    ]) {
      consider('$keg/libexec/openjdk.jdk/Contents/Home');
    }
  } else if (Platform.isLinux) {
    consider(
      _runOrNull('sh', const [
        '-c',
        r'dirname $(dirname $(readlink -f $(which javac 2>/dev/null) 2>/dev/null) 2>/dev/null) 2>/dev/null',
      ]),
    );
    for (final base in const [
      '/usr/lib/jvm/default-java',
      '/usr/lib/jvm/java-21-openjdk-amd64',
      '/usr/lib/jvm/java-17-openjdk-amd64',
    ]) {
      consider(base);
    }
  }

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return LibjvmSearch(candidates, candidate);
    }
  }
  return LibjvmSearch(candidates, null);
}

/// The path to `libjvm` for the current platform.
///
/// Throws a [JniError] listing every path tried when no JDK can be found.
String defaultLibjvmPath({Map<String, String>? environment}) {
  final search = searchLibjvm(environment: environment);
  final resolved = search.resolved;
  if (resolved != null) return resolved;

  throw JniError(
    'Could not locate libjvm. Set JAVA_HOME to a JDK (not a JRE), e.g.\n'
    '  export JAVA_HOME="\$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"\n'
    'Tried:\n${search.candidates.map((c) => '  - $c').join('\n')}',
  );
}

String? _runOrNull(String executable, List<String> arguments) {
  try {
    final result = Process.runSync(executable, arguments);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on ProcessException {
    return null;
  }
}
