/// Shared setup for the test suites.
///
/// Every suite needs the same JVM and the same fixtures jar. Since `dart test`
/// runs each suite as its own isolate inside one shared process, and a JVM is
/// process-global, [testJvm] must never *create* a second VM — it relies on
/// [Jvm.startOrAttach] finding the one an earlier suite already booted.
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

/// The fixtures jar, built by `test/build.sh` from `test/java/`.
///
/// Resolved relative to the package root so the suite runs the same way from
/// any working directory. It belongs to the suite: nothing outside `test/`
/// compiles it, loads it, or depends on what is in it.
String get fixturesJarPath {
  final root = _packageRoot();
  return '$root/test/build/fixtures.jar';
}

/// The JVM shared by every test, booting it on first use.
///
/// Deliberately never calls [Jvm.destroy]: HotSpot cannot start a second VM in
/// the same process, so tearing it down would break every suite that ran
/// afterwards.
Jvm get testJvm {
  final jar = fixturesJarPath;
  if (!File(jar).existsSync()) {
    throw StateError(
      'Fixtures jar not found at $jar.\n'
      'Build it first:  ./test/build.sh   (or run the suite with ./test.sh)',
    );
  }
  return Jvm.startOrAttach(classPath: [jar]);
}

/// Skips the whole suite with an explanation when no JDK is installed, instead
/// of failing with a native error from deep inside `DynamicLibrary.open`.
String? get skipWithoutJdk {
  if (!File(fixturesJarPath).existsSync()) {
    return 'fixtures jar not built; run ./test/build.sh';
  }
  final search = searchLibjvm();
  if (!search.found) {
    return 'no JDK found; set JAVA_HOME (tried: ${search.candidates.join(', ')})';
  }
  return null;
}

/// `com.nfeflash.example.Fixtures`, released after the test.
JavaClass fixturesClass() {
  final clazz = JavaClass.forName(testJvm, 'com.nfeflash.example.Fixtures');
  addTearDown(clazz.release);
  return clazz;
}

/// A `Fixtures` instance built with the no-arg constructor, released after the
/// test.
JavaObject fixturesInstance([JavaClass? clazz]) {
  final instance = (clazz ?? fixturesClass()).newInstance();
  addTearDown(instance.release);
  return instance;
}

/// Registers [ref] for release at the end of the test.
T autoRelease<T extends JavaRef>(T ref) {
  addTearDown(ref.release);
  return ref;
}

/// Registers [object] for release at the end of the test.
JavaObject autoReleaseObject(JavaObject object) {
  addTearDown(object.release);
  return object;
}

/// The package root, found by walking up from this file to the `pubspec.yaml`.
String _packageRoot() {
  var directory = Directory.current;

  // `dart test` runs with the package root as the cwd, but a suite invoked
  // through another tool may not, so walk up as a fallback.
  for (var i = 0; i < 6; i++) {
    if (File('${directory.path}/pubspec.yaml').existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return Directory.current.path;
}
