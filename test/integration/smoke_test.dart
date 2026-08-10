@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  group('smoke', () {
    test('boots a JVM and calls Java', () {
      final jvm = testJvm;
      expect(Jvm.isRunning, isTrue);
      expect(jvm.version, greaterThanOrEqualTo(JniVersion.v1_6));

      final greeter = JavaClass.forName(jvm, 'com.nfeflash.example.Greeter');
      addTearDown(greeter.release);

      final instance = greeter.newInstance('(Ljava/lang/String;)V', ['Dart']);
      addTearDown(instance.release);

      expect(
        instance.call('greet', '()Ljava/lang/String;'),
        allOf(startsWith('Hello, Dart!'), contains('from Java')),
      );
      expect(greeter.callStatic('add', '(II)I', [2, 40]), 42);
    });
  }, skip: skipWithoutJdk);
}
