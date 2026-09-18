/// Detaches a thread this binding attached, and calls Java again afterwards.
///
/// Run as a separate process by `detach_thread_test.dart`. It has to be:
/// `DetachCurrentThread` is illegal for the thread that *created* the VM, and
/// inside the suite there is no way to know whether this isolate is that
/// thread — so the detach has to happen where the order is controlled, on a
/// thread that only ever attached.
///
/// Prints `OK` followed by what the two calls answered, or `FAIL <reason>`.
library;

import 'dart:isolate';

import 'package:java_interop/java_interop.dart';

Future<void> main(List<String> arguments) async {
  final jar = arguments[0];

  try {
    // First in the process, so this isolate's thread is the creator — the one
    // that must not be detached.
    final creator = Jvm.startOrAttach(classPath: [jar]);
    if (!creator.created) {
      print('FAIL the first startOrAttach did not create the VM');
      return;
    }

    print(await Isolate.run(() => _attachDetachReattach(jar)));
  } on Object catch (e) {
    print('FAIL $e');
  }
}

/// Calls Java, detaches, and calls Java again on the same thread.
String _attachDetachReattach(String jar) {
  final jvm = Jvm.startOrAttach(classPath: [jar]);
  if (jvm.created) return 'FAIL the second isolate created a second VM';

  // Before: this call is what attaches the thread in the first place.
  final before = _sum(jvm);

  // Every local reference belongs to the thread, so nothing may be held across
  // the detach — which is exactly why this is the only shape the method is
  // useful in: a thread about to die, with nothing left in hand.
  jvm.detachCurrentThread();

  // After: `env` finds the thread detached again and re-attaches it, which is
  // the behaviour that makes an accidental detach recoverable rather than a
  // crash.
  final after = _sum(jvm);

  return 'OK before=$before after=$after';
}

int _sum(Jvm jvm) {
  final clazz = jvm.findClass('com.nfeflash.example.Fixtures');
  try {
    final method = jvm.staticMethodId(clazz, 'staticSum', '(II)I');
    return jvm.callStaticIntMethod(clazz, method, [
      JValue.fromInt(20),
      JValue.fromInt(22),
    ]);
  } finally {
    clazz.release();
  }
}
