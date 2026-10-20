/// Finding a package's provisioned jars at runtime.
library;

import 'dart:convert';
import 'dart:io';

import '../jvm.dart' show classPathSeparator;
import 'java_runtime_spec.dart';

/// Where a [ResolvedClassPath] came from.
enum ClassPathSource {
  /// Passed to [resolveClassPath] by the caller.
  explicit,

  /// [JavaRuntimeSpec.classPathEnv].
  environment,

  /// The cache directory — the normal case.
  cache,

  /// `.dart_tool/` in the project — development.
  dev,
}

/// A class path [resolveClassPath] found.
class ResolvedClassPath {
  const ResolvedClassPath({
    required this.entries,
    required this.source,
    this.runtimeDir,
  });

  /// The jars and class directories, absolute.
  final List<String> entries;

  final ClassPathSource source;

  /// The runtime directory, when the class path came from one.
  final Directory? runtimeDir;

  /// [entries], joined with the platform's [classPathSeparator].
  String get joined => entries.join(classPathSeparator);

  /// A file of the runtime directory — `logging.properties`, say — or `null`
  /// when there is no runtime directory or no such file.
  File? runtimeFile(String name) {
    final dir = runtimeDir;
    if (dir == null) return null;
    final file = File(joinPath([dir.path, name]));
    return file.existsSync() ? file : null;
  }

  @override
  String toString() =>
      'ResolvedClassPath(${entries.length} entries, from ${source.name})';
}

/// The Java runtime a package needs is not where it should be.
class JavaRuntimeNotProvisioned implements Exception {
  JavaRuntimeNotProvisioned(
    this.reason, {
    this.command,
    this.searched = const [],
  });

  final String reason;

  /// What to run to fix it, from [JavaRuntimeSpec.setupCommand].
  final String? command;

  /// Every place that was looked at, in order.
  final List<String> searched;

  @override
  String toString() {
    final out = StringBuffer('JavaRuntimeNotProvisioned: $reason');
    if (command != null) out.write('\nRun: $command');
    if (searched.isNotEmpty) {
      out.write('\nSearched:\n${searched.map((s) => '  - $s').join('\n')}');
    }
    return out.toString();
  }
}

/// Finds [spec]'s class path.
///
/// In order, the first that gives one wins:
///
/// 1. [explicit], when not empty;
/// 2. [JavaRuntimeSpec.classPathEnv] — a separated list, or a file with one
///    entry per line;
/// 3. the runtime directory under [cacheDirOverride], or under the cache base
///    ([JavaRuntimeSpec.cacheBaseDir]);
/// 4. without an override: also the operating system's default cache, when
///    [JavaRuntimeSpec.cacheDirEnv] pointed somewhere else, and the project's
///    `.dart_tool/` ([JavaRuntimeSpec.devRuntimeDir]).
///
/// A runtime directory counts only when its `manifest.json` names this
/// [JavaRuntimeSpec.runtimeId] (or it has none) and every entry of its
/// `classpath.txt` exists: a half-provisioned cache has to fail here, not
/// with a `NoClassDefFoundError` later. An explicit or environment class path
/// with a missing entry fails too.
///
/// Throws [JavaRuntimeNotProvisioned] — with the setup command and every place
/// searched — when nothing is found.
ResolvedClassPath resolveClassPath(
  JavaRuntimeSpec spec, {
  List<String>? explicit,
  String? cacheDirOverride,
  Map<String, String>? environment,
  String? projectDir,
}) {
  final env = environment ?? Platform.environment;
  final searched = <String>[];

  if (explicit != null && explicit.isNotEmpty) {
    return ResolvedClassPath(
      entries: _existing(spec, explicit, 'the explicit class path'),
      source: ClassPathSource.explicit,
    );
  }

  final fromEnv = spec.classPathEnv == null ? null : env[spec.classPathEnv];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) {
    searched.add('\$${spec.classPathEnv}=${fromEnv.trim()}');
    final entries = _parseClassPathValue(fromEnv.trim());
    if (entries.isNotEmpty) {
      return ResolvedClassPath(
        entries: _existing(spec, entries, '\$${spec.classPathEnv}'),
        source: ClassPathSource.environment,
      );
    }
  }

  final dev = spec.devRuntimeDir(projectDir: projectDir);
  final candidates = <(Directory, ClassPathSource)>[
    (
      spec.runtimeDir(override: cacheDirOverride, environment: env),
      ClassPathSource.cache,
    ),
    if (cacheDirOverride == null) ...[
      if (spec.cacheDirEnv != null && env[spec.cacheDirEnv] != null)
        (
          Directory(
            joinPath([
              spec.defaultCacheBasePath(environment: env),
              spec.runtimeId,
            ]),
          ),
          ClassPathSource.cache,
        ),
      if (dev != null) (dev, ClassPathSource.dev),
    ],
  ];

  for (final (dir, source) in candidates) {
    searched.add(dir.path);
    final entries = readRuntimeClassPath(spec, dir);
    if (entries != null && entries.isNotEmpty) {
      return ResolvedClassPath(
        entries: entries,
        source: source,
        runtimeDir: dir,
      );
    }
  }

  throw JavaRuntimeNotProvisioned(
    'no class path found for ${spec.name} runtime ${spec.runtimeId}',
    command: spec.setupCommand,
    searched: searched,
  );
}

/// The class path recorded in the runtime directory [dir], absolute; `null`
/// when there is none, it belongs to another runtime id, or an entry is
/// missing.
List<String>? readRuntimeClassPath(JavaRuntimeSpec spec, Directory dir) {
  final file = File(joinPath([dir.path, JavaRuntimeSpec.classPathFileName]));
  if (!file.existsSync()) return null;

  final manifest = File(joinPath([dir.path, JavaRuntimeSpec.manifestFileName]));
  if (manifest.existsSync()) {
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is! Map ||
          (decoded['runtimeId'] ?? spec.runtimeId) != spec.runtimeId) {
        return null;
      }
    } on FormatException {
      return null;
    }
  }

  final entries = [
    for (final line in file.readAsLinesSync())
      if (line.trim() case final entry
          when entry.isNotEmpty && !entry.startsWith('#'))
        _isAbsolute(entry) ? entry : joinPath([dir.path, entry]),
  ];
  for (final entry in entries) {
    if (!_exists(entry)) return null;
  }
  return entries;
}

/// A [JavaRuntimeSpec.classPathEnv] value: a separated list, or — when it is
/// one path that is a file other than a jar — a file with one entry per line.
List<String> _parseClassPathValue(String value) {
  if (!value.contains(classPathSeparator) && !value.endsWith('.jar')) {
    final file = File(value);
    if (file.existsSync()) {
      return [
        for (final line in file.readAsLinesSync())
          if (line.trim() case final e when e.isNotEmpty && !e.startsWith('#'))
            e,
      ];
    }
  }
  return [
    for (final entry in value.split(classPathSeparator))
      if (entry.trim().isNotEmpty) entry.trim(),
  ];
}

List<String> _existing(
  JavaRuntimeSpec spec,
  List<String> entries,
  String from,
) {
  final missing = entries.where((e) => !_exists(e)).toList();
  if (missing.isNotEmpty) {
    throw JavaRuntimeNotProvisioned(
      'missing from $from: ${missing.join(', ')}',
      command: spec.setupCommand,
      searched: entries,
    );
  }
  return entries;
}

bool _exists(String path) =>
    File(path).existsSync() || Directory(path).existsSync();

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
