@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

/// The helpers that need no JVM: [JvmOptions], [JavaExceptionClassifier] and
/// what [JavaException] reads from its own chain.
void main() {
  group('JvmOptions', () {
    test('the defaults suit an embedded VM', () {
      expect(const JvmOptions().build(), [
        '-Djava.awt.headless=true',
        '-Dfile.encoding=UTF-8',
        '-Dsun.jnu.encoding=UTF-8',
      ]);
    });

    test('every setting, in order', () {
      expect(
        const JvmOptions(
          headless: false,
          encoding: null,
          timeZone: 'America/Sao_Paulo',
          initialHeapMb: 64,
          maxHeapMb: 512,
          usePerfData: false,
          loggingConfigFile: '/etc/logging.properties',
          systemProperties: {'a.b': 'c'},
          extra: ['-Xss2m'],
        ).build(),
        [
          '-Duser.timezone=America/Sao_Paulo',
          '-Xms64m',
          '-Xmx512m',
          '-XX:-UsePerfData',
          '-Djava.util.logging.config.file=/etc/logging.properties',
          '-Da.b=c',
          '-Xss2m',
        ],
      );
    });
  });

  group('JavaExceptionClassifier', () {
    const classifier = JavaExceptionClassifier<String>(
      [
        ('com.example.ValidationException', 'rejected'),
        ('com.example.LibraryException', 'library'),
        ('java.net.', 'network'),
        ('java.security.KeyStoreException', 'certificate'),
      ],
      wrappers: {'library'},
    );

    JavaException exception(
      String className, [
      List<String> causes = const [],
    ]) => JavaException(
      className: className,
      message: null,
      causes: [for (final cause in causes) JavaCause(cause)],
    );

    test('a class matches by name or by prefix', () {
      expect(classifier.kindOf('java.net.SocketTimeoutException'), 'network');
      expect(classifier.kindOf('com.example.ValidationException'), 'rejected');
      expect(classifier.kindOf('java.lang.IllegalStateException'), isNull);
    });

    test('a wrapper yields to a specific kind further down the chain', () {
      expect(
        classifier.classify(
          exception('com.example.LibraryException', [
            'java.lang.RuntimeException',
            'java.net.SocketTimeoutException',
          ]),
        ),
        'network',
      );
    });

    test('a wrapper is the answer when nothing more specific is there', () {
      expect(
        classifier.classify(
          exception('com.example.LibraryException', [
            'java.lang.IllegalStateException',
          ]),
        ),
        'library',
      );
    });

    test('a specific outer kind wins over a cause', () {
      expect(
        classifier.classify(
          exception('com.example.ValidationException', [
            'java.net.ConnectException',
          ]),
        ),
        'rejected',
      );
    });

    test('nothing matching is null', () {
      expect(classifier.classify(exception('java.lang.Error')), isNull);
    });
  });

  group('JavaException', () {
    test('isFatal sees a fatal error through the chain', () {
      expect(
        JavaException(
          className: 'com.example.LibraryException',
          message: 'x',
          causes: const [JavaCause('java.lang.OutOfMemoryError', 'heap')],
        ).isFatal,
        isTrue,
      );
      expect(
        JavaException(
          className: 'java.lang.IllegalStateException',
          message: 'x',
        ).isFatal,
        isFalse,
      );
    });

    test('missingClass reads the class from the message, slashed or not', () {
      expect(
        JavaException(
          className: 'java.lang.NoClassDefFoundError',
          message: 'org/apache/axiom/om/OMFactory',
        ).missingClass,
        'org.apache.axiom.om.OMFactory',
      );
      expect(
        JavaException(
          className: 'com.example.LibraryException',
          message: 'boot failed',
          causes: const [
            JavaCause(
              'java.lang.ClassNotFoundException',
              'com.example.Missing\$Inner',
            ),
          ],
        ).missingClass,
        r'com.example.Missing$Inner',
      );
      expect(
        JavaException(
          className: 'java.lang.IllegalStateException',
          message: 'com.example.NotAboutClasses',
        ).missingClass,
        isNull,
      );
    });
  });

  group('mapJavaExceptions', () {
    test('maps a JavaException and keeps the stack trace', () {
      StackTrace? original;
      try {
        mapJavaExceptions<void>(() {
          try {
            throw JavaException(className: 'java.lang.X', message: 'boom');
          } catch (_, stack) {
            original = stack;
            rethrow;
          }
        }, (e) => StateError('mapped: ${e.message}'));
        fail('did not throw');
      } on StateError catch (e, stack) {
        expect(e.message, 'mapped: boom');
        expect(stack.toString(), original.toString());
      }
    });

    test('anything else passes through', () {
      expect(
        () => mapJavaExceptions<void>(
          () => throw const FormatException('not Java'),
          (e) => StateError('mapped'),
        ),
        throwsFormatException,
      );
      expect(mapJavaExceptions(() => 42, (e) => StateError('x')), 42);
    });

    test('the async form maps a failed future', () async {
      await expectLater(
        mapJavaExceptionsAsync<void>(
          () async =>
              throw JavaException(className: 'java.lang.X', message: 'later'),
          (e) => StateError('mapped: ${e.message}'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'mapped: later',
          ),
        ),
      );
    });
  });
}
