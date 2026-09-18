@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// `Jvm.detachCurrentThread`, on a thread that only ever attached.
///
/// Needs its own process. JNI forbids detaching the thread that created the VM,
/// and inside the suite there is no telling whether this isolate is that thread
/// — whichever suite ran first created the VM. Here the order is controlled: the
/// main isolate creates, and a child isolate attaches, detaches and calls again.
///
/// The second call is the interesting half. `env` re-resolves the `JNIEnv*` on
/// every access, so a detached thread simply attaches again instead of handing
/// the VM a stale pointer.
void main() {
  group(
    'detachCurrentThread',
    () {
      const fixturePath = 'test/integration/fixtures/detach_thread.dart';

      setUpAll(() {
        expect(
          File(fixturePath).existsSync(),
          isTrue,
          reason: 'fixture script missing',
        );
      });

      test('a detached thread attaches again on the next call', () async {
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

        expect((result.stdout as String).trim(), 'OK before=42 after=42');
      });
    },
    skip: skipWithoutJdk,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
