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

  /// The cause chain, as pure logic.
  ///
  /// Reading it from the VM is covered by `integration/causes_test.dart`; what
  /// matters here is the *matching*, because a wrong answer is not an error —
  /// it silently changes a decision. A caller retries on
  /// `isCausedBy('SocketTimeoutException')` and does not retry on a validation
  /// failure wrapped in the very same outer class.
  group('JavaException causes', () {
    JavaException wrapped() => JavaException(
      className: 'com.example.ServiceException',
      message: 'call failed',
      causes: const [
        JavaCause('java.lang.IllegalStateException', 'connect failed'),
        JavaCause('java.net.SocketTimeoutException', 'connect timed out'),
      ],
    );

    test('an exception with no causes has an empty chain', () {
      final plain = JavaException(
        className: 'java.lang.Exception',
        message: null,
      );

      expect(plain.causes, isEmpty);
      expect(plain.isCausedBy('java.io.IOException'), isFalse);
      expect(plain.causeOf('java.io.IOException'), isNull);
    });

    test('isCausedBy looks at the exception itself as well as the chain', () {
      final exception = wrapped();

      expect(exception.isCausedBy('com.example.ServiceException'), isTrue);
      expect(exception.isCausedBy('ServiceException'), isTrue);
      expect(exception.isCausedBy('java.net.SocketTimeoutException'), isTrue);
      expect(exception.isCausedBy('SocketTimeoutException'), isTrue);
      expect(exception.isCausedBy('java.io.IOException'), isFalse);
    });

    test('causeOf returns the matching link, with its message', () {
      final exception = wrapped();

      expect(
        exception.causeOf('SocketTimeoutException')?.message,
        'connect timed out',
      );
      expect(
        exception.causeOf('IllegalStateException')?.className,
        'java.lang.IllegalStateException',
      );
      expect(exception.causeOf('java.io.IOException'), isNull);
    });

    /// The chain is outermost-first, so the *first* match is the nearest one —
    /// which is what a caller reaching for "why did this fail" wants.
    test('causeOf finds the outermost of two matches', () {
      final exception = JavaException(
        className: 'com.example.Outer',
        message: null,
        causes: const [
          JavaCause('java.io.IOException', 'nearer'),
          JavaCause('java.io.IOException', 'further'),
        ],
      );

      expect(exception.causeOf('java.io.IOException')?.message, 'nearer');
    });

    /// Same rule as [JavaException.isA]: a suffix only matches on a package
    /// boundary, so an unrelated class ending in the same text is not a hit.
    test('a cause matches on a package boundary, not on any suffix', () {
      const cause = JavaCause('java.net.SocketTimeoutException');

      expect(cause.isA('java.net.SocketTimeoutException'), isTrue);
      expect(cause.isA('SocketTimeoutException'), isTrue);
      expect(cause.isA('TimeoutException'), isFalse);
      expect(cause.isA('java.util.concurrent.TimeoutException'), isFalse);
    });

    test('a cause may have no message', () {
      const cause = JavaCause('java.lang.NullPointerException');

      expect(cause.message, isNull);
      expect(cause.isA('NullPointerException'), isTrue);
    });

    test('toString names the causes, outermost first', () {
      final text = wrapped().toString();

      expect(text, contains('com.example.ServiceException'));
      expect(text, contains('caused by'));
      expect(
        text.indexOf('IllegalStateException'),
        lessThan(text.indexOf('SocketTimeoutException')),
        reason: 'the chain reads outermost to innermost',
      );
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
