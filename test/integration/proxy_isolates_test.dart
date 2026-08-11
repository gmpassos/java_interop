@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Proxies in more than one isolate of the same process.
///
/// `RegisterNatives` binds a function pointer to a *class*, and a Dart
/// `NativeCallable.isolateLocal` may only be entered from its own isolate's
/// thread — so if every isolate shared one handler class, the last isolate to
/// bind would silently steal the others' calls, and the first call afterwards
/// would abort the process. Giving each isolate its own class loader, and
/// therefore its own class, is what makes that impossible.
///
/// It runs in a separate process because the failure is an abort, not an
/// exception: inside the test runner it would kill the suite and report nothing.
void main() {
  group(
    'proxies across isolates',
    () {
      const fixturePath = 'test/integration/fixtures/concurrent_proxies.dart';

      setUpAll(() {
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
            'fixture exited with ${result.exitCode} — an abort here means the '
            'isolates shared a binding\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
          );
        }
        return (result.stdout as String).trim();
      }

      test('four isolates each get their own handler class', () async {
        expect(await runFixture(4), startsWith('OK 4'));
      });

      test('the main isolate keeps working after the others exit', () async {
        // The child isolates' callables are gone by then. The main isolate's 200
        // calls afterwards are the actual assertion; the fixture reports how
        // many of its own calls landed.
        expect(await runFixture(2), 'OK 2 201');
      });
    },
    skip: skipWithoutJdk,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
