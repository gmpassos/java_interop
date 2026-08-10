@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

void main() {
  group('JniError', () {
    test('carries and prints its message', () {
      final error = JniError('libjvm not found');
      expect(error.message, 'libjvm not found');
      expect(error.toString(), 'JniError: libjvm not found');
      expect(error, isA<Error>());
    });
  });

  group('JniLookupError', () {
    test('a class lookup has no signature', () {
      final error = JniLookupError('class', 'com.example.Missing');

      expect(error.kind, 'class');
      expect(error.name, 'com.example.Missing');
      expect(error.signature, isNull);
      expect(
        error.toString(),
        'JniLookupError: no such class: com.example.Missing',
      );
    });

    test('a member lookup appends the signature, as javap prints it', () {
      final error = JniLookupError('method', 'greet', '()Ljava/lang/String;');

      expect(error.signature, '()Ljava/lang/String;');
      expect(
        error.toString(),
        'JniLookupError: no such method: greet()Ljava/lang/String;',
      );
    });

    test('is a JniError, so one catch covers binding failures', () {
      expect(JniLookupError('field', 'x', 'I'), isA<JniError>());
    });
  });

  group('JavaException', () {
    test('prints class and message', () {
      final exception = JavaException(
        className: 'java.lang.IllegalStateException',
        message: 'boom',
      );

      expect(
        exception.toString(),
        'JavaException: java.lang.IllegalStateException: boom',
      );
    });

    test('prints just the class when there is no message', () {
      expect(
        JavaException(
          className: 'java.lang.UnsupportedOperationException',
          message: null,
        ).toString(),
        'JavaException: java.lang.UnsupportedOperationException',
      );
      expect(
        JavaException(className: 'java.lang.Error', message: '').toString(),
        'JavaException: java.lang.Error',
      );
    });

    test('isA matches the full name and the simple name', () {
      final exception = JavaException(
        className: 'java.lang.IllegalStateException',
        message: 'boom',
      );

      expect(exception.isA('java.lang.IllegalStateException'), isTrue);
      expect(exception.isA('IllegalStateException'), isTrue);

      // Must not match a different class that merely ends with the same text.
      expect(exception.isA('StateException'), isFalse);
      expect(exception.isA('java.lang.IllegalArgumentException'), isFalse);
    });

    test('isA handles nested class names', () {
      final exception = JavaException(
        className: 'com.nfeflash.example.Fixtures\$FixtureException',
        message: null,
      );

      expect(exception.isA('Fixtures\$FixtureException'), isTrue);
      expect(
        exception.isA('FixtureException'),
        isFalse,
        reason: 'the separator before a nested name is \$, not .',
      );
    });

    test('is an Exception, not an Error: Java throwables are recoverable', () {
      expect(
        JavaException(className: 'java.lang.Exception', message: null),
        isA<Exception>(),
      );
    });

    test('carries the stack trace when one was captured', () {
      final exception = JavaException(
        className: 'java.lang.RuntimeException',
        message: 'x',
        stackTraceText:
            'java.lang.RuntimeException: x\n\tat Foo.bar(Foo.java:1)',
      );

      expect(exception.stackTraceText, contains('at Foo.bar'));
    });
  });

  group('JniResult', () {
    test('names the documented JNI return codes', () {
      expect(JniResult.describe(JniResult.ok), 'JNI_OK');
      expect(JniResult.describe(JniResult.err), 'JNI_ERR');
      expect(JniResult.describe(JniResult.detached), 'JNI_EDETACHED');
      expect(JniResult.describe(JniResult.version), 'JNI_EVERSION');
      expect(JniResult.describe(JniResult.noMemory), 'JNI_ENOMEM');
      expect(JniResult.describe(JniResult.exists), 'JNI_EEXIST');
      expect(JniResult.describe(JniResult.invalidArguments), 'JNI_EINVAL');
    });

    test('falls back to the numeric code for anything unknown', () {
      expect(JniResult.describe(-99), 'unknown code -99');
    });
  });
}
