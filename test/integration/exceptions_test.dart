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

  group('translation', () {
    test('a Java exception becomes a JavaException with class and message', () {
      expect(
        () => fixtures.callStatic(
          'throwIllegalState',
          '(Ljava/lang/String;)V',
          ['boom'],
        ),
        throwsA(
          isA<JavaException>()
              .having(
                (e) => e.className,
                'className',
                'java.lang.IllegalStateException',
              )
              .having((e) => e.message, 'message', 'boom'),
        ),
      );
    });

    test('an exception with no message reports null, not empty', () {
      expect(
        () => fixtures.callStatic('throwWithoutMessage', '()V'),
        throwsA(
          isA<JavaException>()
              .having(
                (e) => e.className,
                'className',
                'java.lang.UnsupportedOperationException',
              )
              .having((e) => e.message, 'message', isNull),
        ),
      );
    });

    test('a checked exception crosses the same way', () {
      expect(
        () => fixtures.callStatic('throwChecked', '()V'),
        throwsA(
          isA<JavaException>()
              .having((e) => e.className, 'className', 'java.lang.Exception')
              .having((e) => e.message, 'message', 'checked failure'),
        ),
      );
    });

    test('a custom exception type keeps its nested class name', () {
      expect(
        () => fixtures.callStatic('throwCustom', '(Ljava/lang/String;)V', [
          'custom',
        ]),
        throwsA(
          isA<JavaException>()
              .having(
                (e) => e.className,
                'className',
                'com.nfeflash.example.Fixtures\$FixtureException',
              )
              .having((e) => e.message, 'message', 'custom'),
        ),
      );
    });

    test('an arithmetic fault from Java arrives as an exception', () {
      expect(
        () => fixtures.callStatic('divide', '(II)I', [1, 0]),
        throwsA(
          isA<JavaException>()
              .having((e) => e.isA('ArithmeticException'), 'isA', isTrue)
              .having((e) => e.message, 'message', '/ by zero'),
        ),
      );
    });

    test('the Java stack trace is captured', () {
      try {
        fixtures.callStatic('divide', '(II)I', [1, 0]);
        fail('expected a JavaException');
      } on JavaException catch (e) {
        expect(e.stackTraceText, isNotNull);
        expect(e.stackTraceText, contains('java.lang.ArithmeticException'));
        expect(e.stackTraceText, contains('com.nfeflash.example.Fixtures'));
      }
    });

    test('toString reads well in a log', () {
      try {
        fixtures.callStatic('throwIllegalState', '(Ljava/lang/String;)V', [
          'bad',
        ]);
        fail('expected a JavaException');
      } on JavaException catch (e) {
        expect(
          e.toString(),
          'JavaException: java.lang.IllegalStateException: bad',
        );
      }
    });
  });

  group('recovery', () {
    // JNI forbids almost every call while an exception is pending, so the
    // binding must clear it. If it did not, the *next* unrelated call would
    // fail with the previous exception and be near-impossible to diagnose.
    test('the VM is usable immediately after an exception', () {
      expect(
        () => fixtures.callStatic('divide', '(II)I', [1, 0]),
        throwsA(isA<JavaException>()),
      );

      expect(fixtures.callStatic('staticSum', '(II)I', [2, 2]), 4);
    });

    test('repeated exceptions do not accumulate state', () {
      for (var i = 0; i < 50; i++) {
        expect(
          () => fixtures.callStatic('divide', '(II)I', [i, 0]),
          throwsA(isA<JavaException>()),
        );
        expect(fixtures.callStatic('staticSum', '(II)I', [i, 1]), i + 1);
      }
    });

    test('an exception inside a local frame still balances the frame', () {
      expect(
        () => jvm.localFrame<void>(() {
          fixtures.callStatic('divide', '(II)I', [1, 0]);
        }),
        throwsA(isA<JavaException>()),
      );

      expect(fixtures.callStatic('staticSum', '(II)I', [1, 1]), 2);
    });

    test('string arguments are released even when the call throws', () {
      // The temporary jstring is allocated before the call; a leak here would
      // only show up as reference-table exhaustion much later.
      for (var i = 0; i < 500; i++) {
        expect(
          () => fixtures.callStatic(
            'throwIllegalState',
            '(Ljava/lang/String;)V',
            ['message $i'],
          ),
          throwsA(isA<JavaException>()),
        );
      }

      expect(fixtures.callStatic('staticSum', '(II)I', [1, 1]), 2);
    });

    test('an exception from a constructor is translated', () {
      final clazz = autoRelease(jvm.findClass('java.lang.Integer'));
      final constructor = jvm.methodId(
        clazz,
        '<init>',
        '(Ljava/lang/String;)V',
      );
      final bad = autoRelease(jvm.newString('not-a-number'));

      expect(
        () => jvm.newObject(clazz, constructor, [
          JValue.fromPointer(bad.pointer),
        ]),
        throwsA(
          isA<JavaException>().having(
            (e) => e.isA('NumberFormatException'),
            'isA',
            isTrue,
          ),
        ),
      );
    });
  });

  group('throwing from Dart', () {
    test('throwJava raises a Java exception and reports it back', () {
      expect(
        () => jvm.throwJava('java.lang.IllegalArgumentException', 'from Dart'),
        throwsA(
          isA<JavaException>()
              .having(
                (e) => e.className,
                'className',
                'java.lang.IllegalArgumentException',
              )
              .having((e) => e.message, 'message', 'from Dart'),
        ),
      );
    });

    test('throwJava leaves the VM usable', () {
      expect(
        () => jvm.throwJava('java.lang.IllegalStateException', 'x'),
        throwsA(isA<JavaException>()),
      );

      expect(fixtures.callStatic('staticSum', '(II)I', [3, 4]), 7);
    });

    test('throwing an unknown class is a lookup error, not a crash', () {
      expect(
        () => jvm.throwJava('com.example.NoSuchException', 'x'),
        throwsA(isA<JniLookupError>()),
      );
    });

    test('a message is optional', () {
      expect(
        () => jvm.throwJava('java.lang.IllegalStateException'),
        throwsA(
          isA<JavaException>().having(
            (e) => e.message,
            'message',
            anyOf(isNull, isEmpty),
          ),
        ),
      );
    });
  });

  group('isA', () {
    test('matches by simple and fully-qualified name', () {
      try {
        fixtures.callStatic('divide', '(II)I', [1, 0]);
        fail('expected a JavaException');
      } on JavaException catch (e) {
        expect(e.isA('java.lang.ArithmeticException'), isTrue);
        expect(e.isA('ArithmeticException'), isTrue);
        expect(e.isA('IllegalStateException'), isFalse);
      }
    });
  });
}
