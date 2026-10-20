@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// What can only be tested in a JVM created for the test: the options it was
/// created with, creating one from a bad `libjvm`, and destroying it.
///
/// Each scenario runs `test/support/fresh_vm_main.dart` in a process of its
/// own — the suites share one VM, created with no options and never destroyed,
/// and a process cannot create a second.
void main() {
  Future<Map<String, Object?>> run(String scenario) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'test/support/fresh_vm_main.dart',
      scenario,
      fixturesJarPath,
    ], workingDirectory: packageRoot);
    expect(
      result.exitCode,
      0,
      reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
    );
    final line = (result.stdout as String)
        .split('\n')
        .lastWhere((l) => l.startsWith('{'));
    return jsonDecode(line) as Map<String, Object?>;
  }

  const timeout = Timeout(Duration(minutes: 2));

  test(
    'a VM created with JvmOptions has every option in effect',
    () async {
      final vm = await run('options');

      expect(vm['created'], isTrue);
      expect(vm['headless'], 'true');
      expect(vm['timeZone'], 'Asia/Tokyo');
      expect(vm['encoding'], 'UTF-8');
      expect(vm['marker'], 'yes');
      // -Xmx96m: the JVM reports a little less than the flag.
      expect(vm['maxMemoryMb'], inInclusiveRange(64, 96));
    },
    timeout: timeout,
    skip: skipWithoutJdk,
  );

  test(
    'on a headless VM, availableFontFamilies lists the fonts',
    () async {
      final vm = await run('options');

      // The suite's own VM is not headless, which on macOS makes this refuse;
      // here is the path that answers.
      expect(vm['fontCount'] as int, greaterThan(0));
      expect(vm['hasDialog'], isTrue);
    },
    timeout: timeout,
    skip: skipWithoutJdk,
  );

  test(
    'info and preflight on a VM this process created',
    () async {
      final vm = await run('options');

      expect(vm['infoAttached'], isFalse);
      expect(vm['infoClassPath'], contains('fixtures.jar'));
      expect(vm['preflightOk'], isTrue);
      expect(vm['preflightAttached'], isFalse);
    },
    timeout: timeout,
    skip: skipWithoutJdk,
  );

  test(
    'a libjvm that does not exist is a JniError naming the path',
    () async {
      final vm = await run('bad-libjvm');

      expect(vm['threw'], 'JniError');
      expect(vm['message'], contains('no-such-libjvm.so'));
    },
    timeout: timeout,
    skip: skipWithoutJdk,
  );

  test(
    'destroy tears the VM down after real work',
    () async {
      final vm = await run('destroy');

      expect(vm['sum'], 5);
      expect(vm['runningAfter'], isFalse);
    },
    timeout: timeout,
    skip: skipWithoutJdk,
  );
}
