/// Reports the context class loader of the thread that *creates* the VM and of
/// a thread this binding attached.
///
/// Run as a separate process by `context_class_loader_test.dart`. It has to be:
/// the suite's own isolate may already have attached before the test runs, and
/// what is being checked is what an attach *leaves behind* on a fresh thread.
///
/// Prints `OK` followed by the three answers, or `FAIL <reason>`.
library;

import 'dart:isolate';

import 'package:java_interop/java_interop.dart';

Future<void> main(List<String> arguments) async {
  final jar = arguments[0];

  try {
    // First in the process, so this one creates the VM: its thread gets the
    // application class loader from the JVM itself.
    final creator = Jvm.startOrAttach(classPath: [jar]);
    final creatorLoader = _contextClassLoader(creator);

    // A second isolate runs on another thread, which the binding attaches. That
    // is the thread `AttachCurrentThread` leaves with a null context class
    // loader unless something fills it in.
    final attached = await Isolate.run(() => _attached(jar));

    if (attached.startsWith('FAIL')) {
      print(attached);
      return;
    }

    print(
      'OK creator=${creatorLoader != null} '
      '$attached',
    );
  } on Object catch (e) {
    print('FAIL $e');
  }
}

/// Attaches on a fresh thread and reports what it found there.
String _attached(String jar) {
  final jvm = Jvm.startOrAttach(classPath: [jar]);

  if (jvm.created) return 'FAIL the second isolate created a second VM';

  final loader = _contextClassLoader(jvm);
  if (loader == null) {
    return 'FAIL an attached thread has no context class loader';
  }

  // And it is the loader that can see the class path, not just any object.
  final system = _systemClassLoader(jvm);

  // A working VM, to prove the attach itself is sound.
  final fixtures = jvm.classFor('com.nfeflash.example.Fixtures');
  final sum = fixtures.callJavaStatic('int staticSum(int, int)', [20, 22]);
  if (sum != 42) return 'FAIL the attached VM did not answer: $sum';

  return 'attached=true same=${loader == system}';
}

/// `Thread.currentThread().getContextClassLoader()`, as text, or `null`.
String? _contextClassLoader(Jvm jvm) => jvm.localFrame(() {
  final thread = jvm
      .classFor('java.lang.Thread')
      .callJavaStaticAs<JavaObject>('java.lang.Thread currentThread()');

  final loader = thread.callJavaAs<JavaObject?>(
    'java.lang.ClassLoader getContextClassLoader()',
  );

  if (loader == null || loader.isNull) return null;
  return loader.callJavaAs<String>('String toString()');
}, capacity: 16);

/// `ClassLoader.getSystemClassLoader()`, as text.
String? _systemClassLoader(Jvm jvm) => jvm.localFrame(() {
  final loader = jvm
      .classFor('java.lang.ClassLoader')
      .callJavaStaticAs<JavaObject>(
        'java.lang.ClassLoader getSystemClassLoader()',
      );
  return loader.callJavaAs<String>('String toString()');
}, capacity: 16);
