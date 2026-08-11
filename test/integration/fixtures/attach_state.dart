/// Reports [Jvm.created] and [Jvm.isAttached] for the isolate that *creates* the
/// VM and for one that only attaches to it.
///
/// Run as a separate process by `attach_state_test.dart`. It has to be: whether
/// the suite's own isolate won the race to create the VM is not knowable from
/// inside it, so `isAttached == true` cannot be asserted there — only the
/// invariant that the flag agrees with the class path. Here the order is
/// controlled, so both states are checked for real.
///
/// Prints `OK` followed by the two states, or `FAIL <reason>`.
library;

import 'dart:isolate';

import 'package:java_interop/java_interop.dart';

Future<void> main(List<String> arguments) async {
  final jar = arguments[0];

  try {
    // First in the process, so this one creates the VM.
    final creator = Jvm.startOrAttach(classPath: [jar]);

    if (!creator.created) {
      print('FAIL the first startOrAttach did not create the VM');
      return;
    }
    if (creator.isAttached) {
      print('FAIL a VM we created reports isAttached');
      return;
    }
    if (creator.classPath.isEmpty) {
      print('FAIL a VM we created lost its class path');
      return;
    }

    // A second isolate: the VM already exists, so this can only attach — and
    // JNI cannot extend or read back the class path of a running VM.
    final attacher = await Isolate.run(() => _attach(jar));

    if (attacher != 'ok') {
      print('FAIL $attacher');
      return;
    }

    print(
      'OK created=${creator.created} attached=${creator.isAttached} '
      'jars=${creator.classPath.length}',
    );
  } on Object catch (e) {
    print('FAIL $e');
  }
}

/// Attaches in a fresh isolate and checks what it reports.
String _attach(String jar) {
  // The class path is passed and deliberately ignored: this is the case the
  // flag exists for, where asking for jars and getting none is silent.
  final jvm = Jvm.startOrAttach(classPath: [jar]);

  if (jvm.created) return 'the second isolate created a second VM';
  if (!jvm.isAttached) return 'an attached VM does not report isAttached';
  if (jvm.classPath.isNotEmpty) {
    return 'an attached VM reported a class path: ${jvm.classPath}';
  }

  // And it is a working VM, not just a plausible-looking object.
  final fixtures = jvm.classFor('com.nfeflash.example.Fixtures');
  final sum = fixtures.callJavaStatic('int staticSum(int, int)', [20, 22]);
  if (sum != 42) return 'the attached VM did not answer: $sum';

  return 'ok';
}
