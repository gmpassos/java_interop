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

      final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');
      addTearDown(fixtures.release);

      // The shape of the quickstart: construct with a String, call an instance
      // method that returns one, then a static method returning a primitive.
      final instance = fixtures.newInstance('(Ljava/lang/String;)V', ['Dart']);
      addTearDown(instance.release);

      expect(instance.call('getLabel', '()Ljava/lang/String;'), 'Dart');
      expect(fixtures.callStatic('staticSum', '(II)I', [2, 40]), 42);
    });
  }, skip: skipWithoutJdk);
}
