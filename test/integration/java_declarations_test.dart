@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;
  late JavaClass fixtures;

  setUpAll(() => jvm = testJvm);
  setUp(() => fixtures = fixturesClass());

  group('callJavaStatic', () {
    test('a declaration replaces the name and the descriptor', () {
      expect(fixtures.callJavaStatic('int staticSum(int, int)', [2, 40]), 42);
    });

    test('agrees with the hand-written descriptor', () {
      expect(
        fixtures.callJavaStatic('int staticSum(int, int)', [2, 40]),
        fixtures.callStatic('staticSum', '(II)I', [2, 40]),
      );
    });

    test('a String return', () {
      expect(
        fixtures.callJavaStatic('String staticConcat(String, String)', [
          'a',
          'b',
        ]),
        'ab',
      );
    });

    test('an array parameter', () {
      expect(
        fixtures.callJavaStatic('int sumInts(int[])', [
          [1, 2, 3],
        ]),
        6,
      );
      expect(
        fixtures.callJavaStatic('String joinStrings(String[])', [
          ['a', 'b'],
        ]),
        'a,b',
      );
      expect(
        fixtures.callJavaStatic('int sumNested(int[][])', [
          [
            [1, 2],
            [3],
          ],
        ]),
        6,
      );
    });

    test('modifiers and parameter names are ignored', () {
      expect(
        fixtures.callJavaStatic('public static int staticSum(int a, int b)', [
          20,
          22,
        ]),
        42,
      );
    });

    test('a declared wrapper parameter still boxes', () {
      expect(fixtures.callJavaStatic('int unboxInteger(Integer)', [42]), 42);
    });

    test('typed with callJavaStaticAs', () {
      expect(
        fixtures.callJavaStaticAs<int>('int staticSum(int, int)', [1, 1]),
        2,
      );
      expect(
        () => fixtures.callJavaStaticAs<String>('int staticSum(int, int)', [
          1,
          1,
        ]),
        throwsA(isA<JniError>()),
      );
    });

    test('a constructor declaration is refused, with a pointer to newJava', () {
      expect(
        () => fixtures.callJavaStatic('(String)'),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('newJava'),
          ),
        ),
      );
    });
  });

  group('newJava', () {
    test('a bare parameter list is a constructor', () {
      final instance = fixtures.newJava('(String, int)', ['demo', 7]);
      addTearDown(instance.release);

      expect(instance.callJava('String getLabel()'), 'demo');
      expect(instance.callJava('int getNumber()'), 7);
    });

    test('an explicit void return means the same thing', () {
      final instance = fixtures.newJava('void (String)', ['solo']);
      addTearDown(instance.release);

      expect(instance.callJava('String getLabel()'), 'solo');
    });

    test('the no-arg constructor', () {
      final instance = fixtures.newJava('()');
      addTearDown(instance.release);

      expect(instance.callJava('String getLabel()'), 'default');
    });
  });

  group('callJava', () {
    test('an instance method', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.callJava('int sum(int, int)', [20, 22]), 42);
      expect(
        instance.callJava('String concat(String, String)', ['a', 'b']),
        'ab',
      );
    });

    test('every primitive, in one call', () {
      final instance = fixturesInstance(fixtures);
      expect(
        instance.callJava(
          'String mixed(boolean, byte, char, short, int, long, float, double)',
          [true, -128, 0x41, -32768, 2147483647, 9223372036854775807, 1.5, 2.5],
        ),
        'true|-128|A|-32768|2147483647|9223372036854775807|1.5|2.5',
      );
    });

    test('a void method', () {
      final instance = fixturesInstance(fixtures);
      instance.callJava('void voidMethod()');
      expect(instance.getJavaField('String stringField'), 'voidMethod called');
    });

    test('typed with callJavaAs', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.callJavaAs<int>('int sum(int, int)', [1, 2]), 3);
    });

    test('works on a JDK class, no fixtures involved', () {
      final builderClass = JavaClass.forName(jvm, 'java.lang.StringBuilder');
      addTearDown(builderClass.release);

      final builder = builderClass.newJava('(String)', ['Hello']);
      addTearDown(builder.release);

      final appended =
          builder.callJava('StringBuilder append(String)', [', Dart'])
              as JavaObject;
      addTearDown(appended.release);

      expect(builder.javaToString(), 'Hello, Dart');
      expect(builder.callJava('int length()'), 11);
    });
  });

  group('fields by declaration', () {
    test('reads and writes an instance field', () {
      final instance = fixturesInstance(fixtures);

      expect(instance.getJavaField('int intField'), 2147483647);
      expect(instance.getJavaField('boolean booleanField'), isTrue);
      expect(instance.getJavaField('double doubleField'), 2.718281828459045);

      instance.setJavaField('String stringField', 'written');
      expect(instance.getJavaField('String stringField'), 'written');
    });

    test('an array field', () {
      final instance = fixturesInstance(fixtures);

      final values = instance.getJavaField('int[] intArrayField') as JavaArray;
      addTearDown(values.release);
      expect(values.toList(), [1, 2, 3]);

      instance.setJavaField('int[] intArrayField', [9, 8]);
      final updated = instance.getJavaField('int[] intArrayField') as JavaArray;
      addTearDown(updated.release);
      expect(updated.toList(), [9, 8]);
    });

    test('a wrapper field still unboxes', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.getJavaField('Integer boxedIntField'), 7);
    });

    test('static fields, with modifiers written out', () {
      fixtures.callStatic('resetStatics', '()V');
      addTearDown(() => fixtures.callStatic('resetStatics', '()V'));

      expect(
        fixtures.getJavaStaticField('public static int staticIntField'),
        -2147483648,
      );

      fixtures.setJavaStaticField('String staticStringField', 'set by name');
      expect(
        fixtures.getJavaStaticField('String staticStringField'),
        'set by name',
      );
    });
  });

  group('the member id cache still applies', () {
    test('the same declaration resolves one id', () {
      final instance = fixtures.newJava('(String, int)', ['x', 1]);
      addTearDown(instance.release);

      for (var i = 0; i < 5; i++) {
        expect(instance.callJava('int sum(int, int)', [i, 1]), i + 1);
      }

      // <init> from newJava, plus sum — resolved once each.
      expect(fixtures.cachedMemberCount, 2);
    });
  });
}
