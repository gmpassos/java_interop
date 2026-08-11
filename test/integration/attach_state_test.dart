@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// `Jvm.created` and `Jvm.isAttached`, both states for real.
///
/// The flag exists because JNI cannot extend the class path of a running VM: if
/// something else booted the JVM first, the jars you asked for are simply not
/// there, and the only signal used to be an empty `Jvm.classPath` — which is
/// also what a VM created *with* an empty class path looks like.
///
/// Proving the `true` side needs a process where the order is controlled. Inside
/// the suite it cannot be: whether this isolate won the race to create the VM
/// depends on which suite ran first, so `diagnostics_test.dart` can only assert
/// the invariant that holds either way.
void main() {
  group(
    'attach state',
    () {
      const fixturePath = 'test/integration/fixtures/attach_state.dart';

      setUpAll(() {
        expect(
          File(fixturePath).existsSync(),
          isTrue,
          reason: 'fixture script missing',
        );
      });

      test('the creator creates and the second isolate attaches', () async {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          fixturePath,
          fixturesJarPath,
        ], workingDirectory: Directory.current.path);

        if (result.exitCode != 0) {
          fail(
            'fixture exited with ${result.exitCode}\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
          );
        }

        expect(
          (result.stdout as String).trim(),
          'OK created=true attached=false jars=1',
        );
      });
    },
    skip: skipWithoutJdk,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
