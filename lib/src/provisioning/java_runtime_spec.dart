/// What a package's Java runtime is, and where it lives on disk.
library;

import 'dart:io';

/// A package's Java runtime: the jars it needs, where they are cached, and
/// how to check that a set of jars is the right one.
///
/// A package that calls into Java libraries has to get their jars onto the
/// machine somehow. The approach here: Maven resolves them **once, at build
/// time**, from a POM the package ships, into a versioned cache directory —
/// and from then on that directory is the deployable artifact. No Maven at
/// runtime, no network, and a `dart compile exe` binary works as long as the
/// directory is there.
///
/// ```dart
/// const reportsRuntime = JavaRuntimeSpec(
///   name: 'my_reports',
///   runtimeId: 'v1-jasper6.21.0',
///   pomPackageFile: 'tool/runtime_pom.xml',
///   cacheDirEnv: 'MY_REPORTS_JAVA_CACHE',
///   classPathEnv: 'MY_REPORTS_JAVA_CLASSPATH',
///   setupCommand: 'dart run my_reports:setup_jars',
///   requiredClasses: {
///     'net.sf.jasperreports.engine.JasperCompileManager': 'jasperreports',
///   },
///   forbiddenClasses: {'jakarta.xml.bind.JAXBContext': 'jakarta.xml.bind-api'},
/// );
/// ```
///
/// The cache is laid out as `<base>/<runtimeId>/`:
///
/// ```text
/// pom.xml          the POM, copied from the package
/// jars/            what Maven resolved
/// classpath.txt    one jar per line, relative to this directory
/// manifest.json    the runtime id, the jars and their sizes
/// ```
///
/// Relative paths make the directory relocatable — it can be copied into a
/// container image as is — and the runtime id in the path means a new set of
/// jars gets a new directory instead of overwriting the one a running
/// deployment uses.
class JavaRuntimeSpec {
  const JavaRuntimeSpec({
    required this.name,
    required this.runtimeId,
    this.pomPackageFile = 'tool/pom.xml',
    this.cacheDirEnv,
    this.classPathEnv,
    this.setupCommand,
    this.requiredClasses = const {},
    this.requiredResources = const [],
    this.requiredResourceContent = const {},
    this.forbiddenClasses = const {},
    this.loggingProperties,
    this.manifestExtras = const {},
  });

  /// The Dart package this runtime belongs to — its directory name in the
  /// cache, and where [pomPackageFile] is looked up.
  final String name;

  /// Which set of jars this is. Change it whenever the POM changes in a way
  /// that matters: it names the cache directory, and a cache with another id
  /// is ignored.
  final String runtimeId;

  /// The POM, as a path relative to the package root (not `lib/`: a POM is
  /// usually in `tool/`).
  final String pomPackageFile;

  /// An environment variable that overrides the cache's base directory, for a
  /// deployment that keeps the cache elsewhere.
  final String? cacheDirEnv;

  /// An environment variable that gives the class path outright — a list
  /// separated by [classPathSeparator], or the path of a file with one entry
  /// per line. The way out for a deployment that resolves jars without Maven.
  final String? classPathEnv;

  /// The command that provisions the runtime, for error messages.
  final String? setupCommand;

  /// Class name → what should provide it. Each must be in the jars.
  final Map<String, String> requiredClasses;

  /// Resource paths (`META-INF/services/…`) that must be in the jars.
  final List<String> requiredResources;

  /// Resource path → text it must contain, in at least one jar.
  ///
  /// For a resource several jars ship at the same path: when they are merged,
  /// one silently replaces the others, and the file being present says
  /// nothing about whether the right one won.
  final Map<String, String> requiredResourceContent;

  /// Class name → what brings it in. None may be in the jars: for the
  /// libraries that conflict with one the runtime depends on.
  final Map<String, String> forbiddenClasses;

  /// A `java.util.logging` configuration written next to the jars at
  /// provisioning, as `logging.properties`, when not `null`.
  final String? loggingProperties;

  /// More entries for `manifest.json` — library versions, say.
  final Map<String, Object?> manifestExtras;

  /// `classpath.txt`.
  static const classPathFileName = 'classpath.txt';

  /// `manifest.json`.
  static const manifestFileName = 'manifest.json';

  /// `jars`.
  static const jarsDirName = 'jars';

  /// `logging.properties`.
  static const loggingPropertiesFileName = 'logging.properties';

  /// The cache's base directory, absolute: [override], then [cacheDirEnv],
  /// then the operating system's cache directory for [name].
  ///
  /// Absolute even when [override] is relative: a relative path turns into a
  /// wrong one in the first child process that runs from another directory —
  /// Maven, for one.
  Directory cacheBaseDir({String? override, Map<String, String>? environment}) {
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim()).absolute;
    }
    final env = environment ?? Platform.environment;
    final fromEnv = cacheDirEnv == null ? null : env[cacheDirEnv];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      return Directory(fromEnv.trim()).absolute;
    }
    return Directory(defaultCacheBasePath(environment: env));
  }

  /// The operating system's cache directory for [name]: `~/Library/Caches`
  /// on macOS, `%LOCALAPPDATA%` on Windows, `$XDG_CACHE_HOME` or `~/.cache`
  /// elsewhere.
  String defaultCacheBasePath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    if (Platform.isMacOS) {
      return _join([env['HOME'] ?? '.', 'Library', 'Caches', name]);
    }
    if (Platform.isWindows) {
      final local =
          env['LOCALAPPDATA'] ??
          _join([env['USERPROFILE'] ?? '.', 'AppData', 'Local']);
      return _join([local, name]);
    }
    final xdg = env['XDG_CACHE_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return _join([xdg.trim(), name]);
    }
    return _join([env['HOME'] ?? '.', '.cache', name]);
  }

  /// `<cacheBaseDir>/<runtimeId>`.
  Directory runtimeDir({String? override, Map<String, String>? environment}) =>
      Directory(
        _join([
          cacheBaseDir(override: override, environment: environment).path,
          runtimeId,
        ]),
      );

  /// `.dart_tool/<name>/<runtimeId>` under [projectDir] (the current
  /// directory by default), or `null` when there is no `.dart_tool`.
  ///
  /// A per-project cache for development, so `dart test` in a checkout works
  /// without touching the home directory.
  Directory? devRuntimeDir({String? projectDir}) {
    final dartTool = Directory(
      _join([projectDir ?? Directory.current.path, '.dart_tool']),
    );
    if (!dartTool.existsSync()) return null;
    return Directory(_join([dartTool.path, name, runtimeId]));
  }

  @override
  String toString() => 'JavaRuntimeSpec($name, $runtimeId)';
}

/// Joins path segments with the platform separator.
String _join(List<String> segments) {
  final separator = Platform.pathSeparator;
  final out = StringBuffer();
  for (final segment in segments) {
    if (segment.isEmpty) continue;
    if (out.isNotEmpty && !out.toString().endsWith(separator)) {
      out.write(separator);
    }
    out.write(segment);
  }
  return out.toString();
}

/// [_join], for the other provisioning files.
String joinPath(List<String> segments) => _join(segments);
