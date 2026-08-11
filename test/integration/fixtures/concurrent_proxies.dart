/// Several isolates each building their own proxy machinery in one JVM.
///
/// Run as a separate process by `proxy_isolates_test.dart`, because the failure
/// this guards against is not an exception: `RegisterNatives` binds per *class*,
/// so if every isolate shared one handler class, the last one to bind would
/// redirect the others' calls into its own `NativeCallable` — and a callable
/// invoked from a thread that is not its isolate's aborts the process. A dead
/// test runner reports nothing useful, so the check lives out here.
///
/// It also covers the thread the isolates run *on*: awaiting `Isolate.run` can
/// resume the main isolate on the thread a child has just freed, so the calls
/// after the children exit are made from a different OS thread than the ones
/// before.
///
/// Prints `OK <isolates> <calls>` on success, or `FAIL <reason>`.
library;

import 'dart:isolate';

import 'package:java_interop/java_interop.dart';

Future<void> main(List<String> arguments) async {
  final jar = arguments[0];
  final isolateCount = arguments.length > 1 ? int.parse(arguments[1]) : 4;

  try {
    final jvm = Jvm.startOrAttach(classPath: [jar]);
    final fixtures = jvm.classFor('com.nfeflash.example.Fixtures');

    var mine = 0;
    final proxy = jvm.implementInterface(
      'java.util.Comparator',
      onInvoke: (call) {
        mine++;
        return -1;
      },
    );

    try {
      if (_compare(fixtures, proxy) != -1) {
        print('FAIL the main isolate proxy did not answer');
        return;
      }

      final results = await _runChildren(jar, isolateCount);
      final wrong = results.where((r) => r != 'ok').toList();
      if (wrong.isNotEmpty) {
        print('FAIL children: $wrong');
        return;
      }

      // Every child has exited, taking its callables with it, and this isolate
      // may well be running on a thread one of them used. If the bindings were
      // shared, this would abort the process rather than return.
      for (var i = 0; i < 200; i++) {
        if (_compare(fixtures, proxy) != -1) {
          print('FAIL the main isolate proxy stopped answering');
          return;
        }
      }

      print('OK $isolateCount $mine');
    } finally {
      // Without this the isolate stays alive for a callback that will never
      // come, and the process hangs instead of reporting.
      proxy.release();
    }
  } on Object catch (e) {
    print('FAIL $e');
  }
}

/// Spawns the children.
///
/// A function of its own so the closure below captures nothing but [jar] and the
/// index: a closure sharing a scope with a [JavaProxy] drags the proxy's
/// `NativeCallable` into the isolate message, which is rejected.
Future<List<String>> _runChildren(String jar, int count) => Future.wait([
  for (var i = 0; i < count; i++) Isolate.run(() => _childIsolate(jar, i)),
]);

/// One `compare` through [proxy], returning what Java got back.
Object? _compare(JavaClass fixtures, JavaProxy proxy) =>
    fixtures.callJavaStatic(
      'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
      [proxy.instance, 1, 2, 1],
    );

/// Builds a proxy in a fresh isolate and checks it answers with its own value.
String _childIsolate(String jar, int index) {
  final jvm = Jvm.startOrAttach(classPath: [jar]);
  final fixtures = jvm.classFor('com.nfeflash.example.Fixtures');

  final proxy = jvm.implementInterface(
    'java.util.Comparator',
    onInvoke: (call) => index,
  );

  try {
    for (var i = 0; i < 50; i++) {
      final got = _compare(fixtures, proxy);
      if (got != index) return 'isolate $index got $got';
    }
    return 'ok';
  } finally {
    proxy.release();
  }
}
