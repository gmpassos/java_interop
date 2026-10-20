/// Checking a set of jars before a JVM ever loads them.
library;

import 'dart:convert';
import 'dart:io';

import 'jar_file.dart';
import 'java_runtime_spec.dart';

/// What [verifyJars] found.
class JarVerification {
  const JarVerification({
    required this.jarCount,
    required this.missingClasses,
    required this.missingResources,
    required this.wrongResourceContent,
    required this.forbiddenFound,
    required this.unreadable,
  });

  /// How many jars were read.
  final int jarCount;

  /// Required classes that no entry provides, with what should have.
  final Map<String, String> missingClasses;

  /// Required resources that no entry provides.
  final List<String> missingResources;

  /// Resources present, but none of them with the required text — resource →
  /// the text.
  final Map<String, String> wrongResourceContent;

  /// Forbidden classes that are present, with what brings them in.
  final Map<String, String> forbiddenFound;

  /// Class-path entries that could not be read as a jar or a directory, with
  /// why. A broken download looks like this.
  final Map<String, String> unreadable;

  bool get ok =>
      missingClasses.isEmpty &&
      missingResources.isEmpty &&
      wrongResourceContent.isEmpty &&
      forbiddenFound.isEmpty &&
      unreadable.isEmpty;

  /// A report for a person: what is wrong, and what to do about each.
  String describe() {
    if (ok) return 'class path verified: $jarCount jars, everything in place.';
    final out = StringBuffer('class path invalid ($jarCount jars):\n');
    for (final MapEntry(:key, :value) in unreadable.entries) {
      out.writeln('  - unreadable: $key ($value)');
    }
    for (final MapEntry(:key, :value) in missingClasses.entries) {
      out.writeln('  - missing class: $key — expected from $value');
    }
    for (final resource in missingResources) {
      out.writeln('  - missing resource: $resource');
    }
    for (final MapEntry(:key, :value) in wrongResourceContent.entries) {
      out.writeln(
        '  - $key is present, but no copy contains "$value" — the jar '
        'whose copy does is missing, or a merge kept another jar\'s',
      );
    }
    for (final MapEntry(:key, :value) in forbiddenFound.entries) {
      out.writeln('  - forbidden class present: $key — remove $value');
    }
    return out.toString();
  }

  @override
  String toString() => describe();
}

/// Checks [classPath] — jars and class directories — against [spec]'s
/// required, forbidden and content rules, without starting a JVM.
///
/// The point is to fail at provisioning, naming the artifact, rather than
/// with a `NoClassDefFoundError` deep inside a library the first time the one
/// code path that needs the class runs.
JarVerification verifyJars(JavaRuntimeSpec spec, List<String> classPath) {
  final entries = <String>{};
  final contentFound = <String>{};
  final unreadable = <String, String>{};
  var jarCount = 0;

  for (final path in classPath) {
    try {
      if (FileSystemEntity.isDirectorySync(path)) {
        _scanDirectory(spec, path, entries, contentFound);
        continue;
      }
      if (!File(path).existsSync()) {
        unreadable[path] = 'does not exist';
        continue;
      }
      final jar = JarFile.open(path);
      // Read the content before counting the jar in: a jar whose entries
      // cannot be read is unreadable, not half-counted.
      final found = <String>{
        for (final MapEntry(key: name, value: wanted)
            in spec.requiredResourceContent.entries)
          if (jar.contains(name) && jar.readText(name)!.contains(wanted)) name,
      };
      jarCount++;
      entries.addAll(jar.names);
      contentFound.addAll(found);
    } on FormatException catch (e) {
      unreadable[path] = e.message;
    } on FileSystemException catch (e) {
      unreadable[path] = e.message;
    }
  }

  bool hasClass(String className) =>
      entries.contains('${className.replaceAll('.', '/')}.class');

  return JarVerification(
    jarCount: jarCount,
    missingClasses: {
      for (final MapEntry(:key, :value) in spec.requiredClasses.entries)
        if (!hasClass(key)) key: value,
    },
    missingResources: [
      for (final resource in {
        ...spec.requiredResources,
        ...spec.requiredResourceContent.keys,
      })
        if (!entries.contains(resource)) resource,
    ],
    wrongResourceContent: {
      for (final MapEntry(:key, :value) in spec.requiredResourceContent.entries)
        if (entries.contains(key) && !contentFound.contains(key)) key: value,
    },
    forbiddenFound: {
      for (final MapEntry(:key, :value) in spec.forbiddenClasses.entries)
        if (hasClass(key)) key: value,
    },
    unreadable: unreadable,
  );
}

/// Adds a class directory's files to [entries], by their names relative to
/// it, `/`-separated as in a jar.
void _scanDirectory(
  JavaRuntimeSpec spec,
  String path,
  Set<String> entries,
  Set<String> contentFound,
) {
  var root = Directory(path).absolute.path;
  // `classes/` and `classes` are the same root.
  while (root.length > 1 &&
      (root.endsWith('/') || root.endsWith(Platform.pathSeparator))) {
    root = root.substring(0, root.length - 1);
  }
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is! File) continue;
    var name = entity.path.substring(root.length);
    while (name.startsWith('/') || name.startsWith(Platform.pathSeparator)) {
      name = name.substring(1);
    }
    name = name.replaceAll(Platform.pathSeparator, '/');
    entries.add(name);
    final wanted = spec.requiredResourceContent[name];
    if (wanted != null &&
        utf8
            .decode(entity.readAsBytesSync(), allowMalformed: true)
            .contains(wanted)) {
      contentFound.add(name);
    }
  }
}
