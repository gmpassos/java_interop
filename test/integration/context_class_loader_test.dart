@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// The context class loader of a thread the binding attached.
///
/// `AttachCurrentThread` leaves the new `java.lang.Thread` with a **null**
/// context class loader, while the thread that created the VM gets the
/// application one. Since a Dart isolate can resume on any thread of the pool,
/// whoever discovers implementations through the context loader —
/// `ServiceLoader`, JAXB, StAX, JAXP — would behave differently from call to
/// call. It cost a real investigation: Axis2 dereferences that loader unguarded
/// and logged a `NullPointerException` on some SEFAZ requests and not others.
///
/// Needs its own process. Inside the suite the isolate may have attached long
/// before this test runs, and what is under test is what the attach leaves
/// behind on a *fresh* thread.
void main() {
  group(
    'context class loader',
    () {
      const fixturePath = 'test/integration/fixtures/context_class_loader.dart';

      setUpAll(() {
        expect(
          File(fixturePath).existsSync(),
          isTrue,
          reason: 'fixture script missing',
        );
      });

      test('an attached thread gets the system class loader', () async {
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
          'OK creator=true attached=true same=true',
        );
      });
    },
    skip: skipWithoutJdk,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
