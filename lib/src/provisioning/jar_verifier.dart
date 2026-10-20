/// Checking a set of jars before a JVM ever loads them.
library;

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
        '  - $key is present, but none declares "$value" — another '
        'jar\'s file of the same name won',
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
    if (FileSystemEntity.isDirectorySync(path)) {
      final root = Directory(path).absolute.path;
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File) continue;
        final name = entity.path
            .substring(root.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        entries.add(name);
        final wanted = spec.requiredResourceContent[name];
        if (wanted != null && entity.readAsStringSync().contains(wanted)) {
          contentFound.add(name);
        }
      }
      continue;
    }

    if (!File(path).existsSync()) {
      unreadable[path] = 'does not exist';
      continue;
    }
    final JarFile jar;
    try {
      jar = JarFile.open(path);
    } on FormatException catch (e) {
      unreadable[path] = e.message;
      continue;
    }
    jarCount++;
    entries.addAll(jar.names);
    for (final MapEntry(key: name, value: wanted)
        in spec.requiredResourceContent.entries) {
      if (contentFound.contains(name) || !jar.contains(name)) continue;
      if (jar.readText(name)?.contains(wanted) ?? false) contentFound.add(name);
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
