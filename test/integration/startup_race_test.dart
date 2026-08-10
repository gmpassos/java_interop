@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Regression test for the JVM startup race.
///
/// `JNI_CreateJavaVM` may run only once per process, and HotSpot rejects the
/// second caller with `JNI_EEXIST` as soon as the first one *starts* — but only
/// publishes the VM to `JNI_GetCreatedJavaVMs` once it has finished booting. An
/// isolate that loses that race therefore sees neither a usable VM nor a
/// creatable one, and used to fail outright.
///
/// This is exactly what `dart test` produces, since it runs suites
/// concurrently as isolates of one process. It has to run in a *fresh* process:
/// once any VM exists, the race is over and cannot recur.
void main() {
  group(
    'concurrent JVM startup',
    () {
      late String fixturePath;

      setUpAll(() {
        fixturePath = 'test/integration/fixtures/concurrent_start.dart';
        expect(
          File(fixturePath).existsSync(),
          isTrue,
          reason: 'fixture script missing',
        );
      });

      Future<String> runFixture(int isolates) async {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          fixturePath,
          fixturesJarPath,
          '$isolates',
        ], workingDirectory: Directory.current.path);

        if (result.exitCode != 0) {
          fail(
            'fixture exited with ${result.exitCode}\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
          );
        }
        return (result.stdout as String).trim();
      }

      test('8 isolates racing to start a JVM all succeed', () async {
        expect(await runFixture(8), 'OK 8');
      });

      test('the race is survivable repeatedly', () async {
        // Timing-dependent, so it is run more than once: a fix that merely
        // narrows the window rather than closing it fails here intermittently.
        for (var attempt = 0; attempt < 3; attempt++) {
          expect(await runFixture(6), 'OK 6', reason: 'attempt $attempt');
        }
      });
    },
    skip: skipWithoutJdk,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
