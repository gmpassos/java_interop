/// A program that creates a JVM of its own, for the tests that need one.
///
/// A process can create a JVM once, and the test suites share the one the
/// first suite created — with no VM options, and never destroyed. What depends
/// on the options a VM was *created* with (headless AWT, the time zone, the
/// heap), on creating one at all (a bad `libjvm`), or on tearing it down
/// (`destroy`) can only be tested in a process of its own. `fresh_vm_test.dart`
/// runs this with a scenario name and reads the JSON it prints.
///
/// ```sh
/// dart test/support/fresh_vm_main.dart <scenario> <fixtures.jar>
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:java_interop/java_interop.dart';

void main(List<String> args) {
  final scenario = args[0];
  final jar = args[1];

  final result = switch (scenario) {
    'options' => _options(jar),
    'bad-libjvm' => _badLibjvm(jar),
    'destroy' => _destroy(jar),
    _ => throw ArgumentError('unknown scenario $scenario'),
  };
  stdout.writeln(jsonEncode(result));
}

/// A VM created with [JvmOptions]: every option took effect, and the
/// headless-only paths work.
Map<String, Object?> _options(String jar) {
  final jvm = Jvm.startOrAttach(
    classPath: [jar],
    vmOptions: const JvmOptions(
      timeZone: 'Asia/Tokyo',
      maxHeapMb: 96,
      usePerfData: false,
      systemProperties: {'fresh.vm.marker': 'yes'},
    ).build(),
  );

  final maxMemory = jvm.localFrame(() {
    final runtime = jvm
        .classFor('java.lang.Runtime')
        .callJavaStaticAs<JavaObject>('static Runtime getRuntime()');
    return runtime.callJavaAs<int>('long maxMemory()');
  }, capacity: 8);

  final fonts = jvm.availableFontFamilies();
  final info = jvm.info();
  final preflight = jvm.preflight(
    classes: {'com.nfeflash.example.Fixtures': 'fixtures'},
  );

  return {
    'created': jvm.created,
    'headless': jvm.systemProperty('java.awt.headless'),
    'timeZone': jvm.systemProperty('user.timezone'),
    'encoding': jvm.systemProperty('file.encoding'),
    'marker': jvm.systemProperty('fresh.vm.marker'),
    'maxMemoryMb': maxMemory ~/ (1024 * 1024),
    'fontCount': fonts.length,
    'hasDialog': fonts.contains('Dialog'),
    'infoAttached': info.attached,
    'infoClassPath': info.classPath,
    'preflightOk': preflight.ok,
    'preflightAttached': preflight.attached,
  };
}

/// A path that is not a `libjvm` fails as a [JniError] naming it, rather than
/// as a native crash.
Map<String, Object?> _badLibjvm(String jar) {
  try {
    Jvm.startOrAttach(
      libjvmPath: '${Directory.systemTemp.path}/no-such-libjvm.so',
      classPath: [jar],
    );
    return {'threw': null};
  } on JniError catch (e) {
    return {'threw': 'JniError', 'message': e.message};
  }
}

/// `destroy` tears the VM down cleanly, after real work, and leaves the
/// binding reporting no VM.
Map<String, Object?> _destroy(String jar) {
  final jvm = Jvm.startOrAttach(
    classPath: [jar],
    vmOptions: const JvmOptions().build(),
  );
  final sum = jvm.classFor('com.nfeflash.example.Fixtures').callJavaStatic(
    'static int staticSum(int, int)',
    [2, 3],
  );
  jvm.releaseCachedClasses();
  jvm.destroy();
  return {'sum': sum, 'runningAfter': Jvm.isRunning};
}
