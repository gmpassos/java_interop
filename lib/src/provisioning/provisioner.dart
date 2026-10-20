/// Resolving a package's jars with Maven, once, into its cache directory.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../jvm.dart' show classPathSeparator;
import 'jar_verifier.dart';
import 'java_runtime_spec.dart';

/// What [provisionJavaRuntime] did.
class ProvisionResult {
  const ProvisionResult({
    required this.runtimeDir,
    required this.verification,
    required this.provisioned,
    this.jarCount = 0,
    this.totalBytes = 0,
  });

  /// Where the runtime is.
  final Directory runtimeDir;

  /// The check of the jars, provisioned now or before.
  final JarVerification verification;

  /// `false` when the runtime was already there and was only verified.
  final bool provisioned;

  final int jarCount;
  final int totalBytes;

  bool get ok => verification.ok;
}

/// Maven is not installed, or not where it was said to be.
class MavenNotFound implements Exception {
  MavenNotFound(this.searched);

  final List<String> searched;

  @override
  String toString() =>
      'MavenNotFound: searched ${searched.join(', ')}, and the PATH';
}

/// Maven ran and failed.
class MavenFailed implements Exception {
  MavenFailed(this.exitCode, this.output);

  final int exitCode;

  /// Maven's stdout and stderr.
  final String output;

  @override
  String toString() => 'MavenFailed: exit code $exitCode\n$output';
}

/// Resolves [spec]'s jars with Maven into its runtime directory, writes
/// `classpath.txt` and `manifest.json`, and verifies the result.
///
/// Already provisioned (a `jars/` directory exists) and not [force]d: only
/// verifies. [cacheDir] overrides the cache base; [maven] is the `mvn` to
/// run; [offline] runs it with `-o`. [log] receives progress lines.
///
/// Maven runs `dependency:copy-dependencies` with `-DincludeScope=runtime` —
/// the default copies every scope, test included. `classpath.txt` is written
/// from the directory listing with relative paths, not from
/// `dependency:build-classpath`, whose paths point into `~/.m2` and make the
/// cache impossible to relocate.
///
/// Throws [MavenNotFound], [MavenFailed], or a [StateError] when the POM
/// cannot be found or Maven copied nothing.
Future<ProvisionResult> provisionJavaRuntime(
  JavaRuntimeSpec spec, {
  String? cacheDir,
  String? maven,
  bool offline = false,
  bool force = false,
  void Function(String line)? log,
  Map<String, String>? environment,
}) async {
  final runtimeDir = spec.runtimeDir(
    override: cacheDir,
    environment: environment,
  );
  final jarsDir = Directory(
    joinPath([runtimeDir.path, JavaRuntimeSpec.jarsDirName]),
  );

  if (jarsDir.existsSync() && !force) {
    log?.call('already provisioned in ${runtimeDir.path}');
    return ProvisionResult(
      runtimeDir: runtimeDir,
      verification: verifyJars(spec, _recorded(spec, runtimeDir)),
      provisioned: false,
    );
  }

  final mvn = await locateMaven(explicit: maven, environment: environment);
  log?.call('maven: $mvn');

  runtimeDir.createSync(recursive: true);
  if (jarsDir.existsSync()) jarsDir.deleteSync(recursive: true);
  final pom = File(joinPath([runtimeDir.path, 'pom.xml']))
    ..writeAsStringSync(await readPackagePom(spec));

  log?.call('resolving dependencies...');
  final result = await Process.run(mvn, [
    '-B',
    '-f',
    pom.path,
    if (offline) '-o',
    '-DincludeScope=runtime',
    '-DoutputDirectory=${JavaRuntimeSpec.jarsDirName}',
    'dependency:copy-dependencies',
  ], workingDirectory: runtimeDir.path);
  if (result.exitCode != 0) {
    throw MavenFailed(result.exitCode, '${result.stdout}${result.stderr}');
  }

  final jars = jarsDir.existsSync()
      ? (jarsDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jar'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  if (jars.isEmpty) {
    throw StateError('Maven copied no jars into ${jarsDir.path}');
  }
  String nameOf(File f) => f.uri.pathSegments.last;

  File(
    joinPath([runtimeDir.path, JavaRuntimeSpec.classPathFileName]),
  ).writeAsStringSync(
    '${['# Written by provisionJavaRuntime. Paths are relative to this directory.', for (final jar in jars) '${JavaRuntimeSpec.jarsDirName}/${nameOf(jar)}'].join('\n')}\n',
  );

  final logging = spec.loggingProperties;
  if (logging != null) {
    File(
      joinPath([runtimeDir.path, JavaRuntimeSpec.loggingPropertiesFileName]),
    ).writeAsStringSync(logging);
  }

  final verification = verifyJars(spec, _recorded(spec, runtimeDir));
  final totalBytes = jars.fold<int>(0, (sum, f) => sum + f.lengthSync());

  File(
    joinPath([runtimeDir.path, JavaRuntimeSpec.manifestFileName]),
  ).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'runtimeId': spec.runtimeId,
      ...spec.manifestExtras,
      'jars': [
        for (final jar in jars) {'name': nameOf(jar), 'size': jar.lengthSync()},
      ],
      'verified': verification.ok,
    })}\n',
  );

  log?.call(
    '${jars.length} jars (${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} '
    'MB) in ${runtimeDir.path}',
  );
  return ProvisionResult(
    runtimeDir: runtimeDir,
    verification: verification,
    provisioned: true,
    jarCount: jars.length,
    totalBytes: totalBytes,
  );
}

/// The entries `classpath.txt` in [runtimeDir] lists, absolute, whether or
/// not they exist — the verifier reports the missing ones.
List<String> _recorded(JavaRuntimeSpec spec, Directory runtimeDir) {
  final file = File(
    joinPath([runtimeDir.path, JavaRuntimeSpec.classPathFileName]),
  );
  if (!file.existsSync()) return const [];
  return [
    for (final line in file.readAsLinesSync())
      if (line.trim() case final e when e.isNotEmpty && !e.startsWith('#'))
        joinPath([runtimeDir.path, e]),
  ];
}

/// [spec]'s POM, read from its package ([JavaRuntimeSpec.pomPackageFile]
/// under the package root), or from the current directory when the package
/// cannot be resolved — running from the package's own checkout.
///
/// The package root is found from its `package:` URI, which points into
/// `lib/`; a POM lives beside `lib/`, out of `package:` reach.
Future<String> readPackagePom(JavaRuntimeSpec spec) async {
  final searched = <String>[];
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:${spec.name}/'),
  );
  if (lib != null && lib.scheme == 'file') {
    final root = Directory.fromUri(lib).parent;
    final pom = File(joinPath([root.path, spec.pomPackageFile]));
    searched.add(pom.path);
    if (pom.existsSync()) return pom.readAsStringSync();
  }
  final local = File(joinPath([Directory.current.path, spec.pomPackageFile]));
  searched.add(local.path);
  if (local.existsSync()) return local.readAsStringSync();

  throw StateError(
    '${spec.pomPackageFile} of ${spec.name} not found. Searched:\n'
    '${searched.map((s) => '  - $s').join('\n')}\n'
    'Run from a package that depends on ${spec.name}, after `dart pub get`.',
  );
}

/// The `mvn` to run: [explicit] and nothing else when given; otherwise
/// `$MAVEN_HOME`/`$M2_HOME`, the usual install locations, then the `PATH`.
/// Throws [MavenNotFound].
Future<String> locateMaven({
  String? explicit,
  Map<String, String>? environment,
}) async {
  if (explicit != null && explicit.trim().isNotEmpty) {
    // Asked for one in particular: never quietly run another.
    if (File(explicit.trim()).existsSync()) return explicit.trim();
    throw MavenNotFound([explicit.trim()]);
  }

  final env = environment ?? Platform.environment;
  final executable = Platform.isWindows ? 'mvn.cmd' : 'mvn';
  final home = env['MAVEN_HOME'] ?? env['M2_HOME'];
  final candidates = [
    if (home != null && home.trim().isNotEmpty)
      joinPath([home.trim(), 'bin', executable]),
    if (!Platform.isWindows) ...[
      '/opt/homebrew/bin/mvn',
      '/usr/local/bin/mvn',
      '/usr/bin/mvn',
    ],
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }

  try {
    final which = await Process.run(Platform.isWindows ? 'where' : 'which', [
      'mvn',
    ]);
    if (which.exitCode == 0) {
      final found = (which.stdout as String).trim().split('\n').first.trim();
      if (found.isNotEmpty && File(found).existsSync()) return found;
    }
  } on ProcessException {
    // No `which`.
  }
  throw MavenNotFound(candidates);
}

/// A complete `setup_jars` command for [spec], returning the exit code:
/// `0` ok, `1` usage, `2` Maven not found, `3` resolution failed, `4`
/// verification failed.
///
/// A package's whole `bin/setup_jars.dart` can be:
///
/// ```dart
/// import 'dart:io';
/// import 'package:java_interop/provisioning.dart';
/// import 'package:my_reports/src/java_runtime.dart';
///
/// Future<void> main(List<String> args) async =>
///     exit(await runProvisioningCli(reportsRuntime, args));
/// ```
///
/// Options: `--cache-dir <dir>`, `--maven <path>`, `--offline`, `--force`,
/// `--verify-only`, `--print-classpath`, `-h`/`--help`.
Future<int> runProvisioningCli(
  JavaRuntimeSpec spec,
  List<String> args, {
  IOSink? out,
  IOSink? err,
  Map<String, String>? environment,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

  String? cacheDir;
  String? maven;
  var offline = false;
  var force = false;
  var verifyOnly = false;
  var printClassPath = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--cache-dir' when i + 1 < args.length:
        cacheDir = args[++i];
      case '--maven' when i + 1 < args.length:
        maven = args[++i];
      case '--offline':
        offline = true;
      case '--force':
        force = true;
      case '--verify-only':
        verifyOnly = true;
      case '--print-classpath':
        printClassPath = true;
      case '-h' || '--help':
        stdoutSink.writeln(_usage(spec));
        return 0;
      default:
        stderrSink.writeln(_usage(spec));
        return 1;
    }
  }

  final runtimeDir = spec.runtimeDir(
    override: cacheDir,
    environment: environment,
  );

  if (printClassPath || verifyOnly) {
    final recorded = _recorded(spec, runtimeDir);
    if (recorded.isEmpty) {
      stderrSink.writeln('not provisioned in ${runtimeDir.path}');
      return 3;
    }
    if (printClassPath) {
      stdoutSink.writeln(recorded.join(classPathSeparator));
      return 0;
    }
    final verification = verifyJars(spec, recorded);
    (verification.ok ? stdoutSink : stderrSink).writeln(
      verification.describe(),
    );
    return verification.ok ? 0 : 4;
  }

  try {
    final result = await provisionJavaRuntime(
      spec,
      cacheDir: cacheDir,
      maven: maven,
      offline: offline,
      force: force,
      log: stdoutSink.writeln,
      environment: environment,
    );
    (result.ok ? stdoutSink : stderrSink).writeln(
      result.verification.describe(),
    );
    if (result.ok && spec.cacheDirEnv != null) {
      stdoutSink.writeln(
        'For a compiled binary elsewhere, copy the cache and export:\n'
        '  ${spec.cacheDirEnv}='
        '${spec.cacheBaseDir(override: cacheDir, environment: environment).path}',
      );
    }
    return result.ok ? 0 : 4;
  } on MavenNotFound catch (e) {
    stderrSink.writeln(
      'Maven not found ($e).\n'
      'It is needed once, to build the cache: install it, or provision on a '
      'build machine and copy the cache'
      '${spec.cacheDirEnv == null ? '' : ' (pointing \$${spec.cacheDirEnv} at it)'}'
      '${spec.classPathEnv == null ? '' : ', or give the class path in \$${spec.classPathEnv}'}'
      '.',
    );
    return 2;
  } on MavenFailed catch (e) {
    stderrSink.writeln('Maven failed (exit code ${e.exitCode}):\n${e.output}');
    return 3;
  } on StateError catch (e) {
    stderrSink.writeln(e.message);
    return 3;
  }
}

String _usage(JavaRuntimeSpec spec) =>
    '''
usage: ${spec.setupCommand ?? 'setup_jars'} [options]

Resolves the Java libraries of ${spec.name} (runtime ${spec.runtimeId}) with
Maven into a versioned cache directory.

  --cache-dir <dir>   the cache base directory${spec.cacheDirEnv == null ? '' : ' (default: \$${spec.cacheDirEnv},\n                      or the system cache)'}
  --maven <path>      the mvn executable
  --offline           run Maven offline (-o)
  --force             provision again even if already there
  --verify-only       only verify what is provisioned
  --print-classpath   print the class path and exit
  -h, --help          this help''';
