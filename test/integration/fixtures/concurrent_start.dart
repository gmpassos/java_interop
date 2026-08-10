/// Spawns several isolates that all call [Jvm.startOrAttach] at once, in a
/// process where no JVM exists yet.
///
/// Run as a separate process by `startup_race_test.dart`: the race only exists
/// before the first VM is created, so it cannot be reproduced inside a test
/// process that has already booted one.
///
/// Prints `OK <n>` on success, or `FAIL <error>`.
library;

import 'dart:isolate';

import 'package:java_interop/java_interop.dart';

Future<void> main(List<String> arguments) async {
  final jar = arguments[0];
  final isolateCount = arguments.length > 1 ? int.parse(arguments[1]) : 8;

  try {
    final results = await Future.wait([
      for (var i = 0; i < isolateCount; i++)
        Isolate.run(() {
          final jvm = Jvm.startOrAttach(classPath: [jar]);
          final fixtures = JavaClass.forName(
            jvm,
            'com.nfeflash.example.Fixtures',
          );
          try {
            return fixtures.callStatic('staticSum', '(II)I', [20, 22]) as int;
          } finally {
            fixtures.release();
          }
        }),
    ]);

    if (results.any((r) => r != 42)) {
      print('FAIL unexpected results: $results');
      return;
    }
    print('OK ${results.length}');
  } on Object catch (e) {
    print('FAIL $e');
  }
}
