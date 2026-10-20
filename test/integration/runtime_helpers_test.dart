@TestOn('vm')
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// The helpers that ask the running VM: preflight, info, fonts, enums,
/// `java.util.logging` and `java.time`.
void main() {
  group('preflight', () {
    test('passes when everything resolves', () {
      final report = testJvm.preflight(
        classes: {'com.nfeflash.example.Fixtures': 'the fixtures jar'},
        resources: ['com/nfeflash/example/Fixtures.class'],
      );
      expect(report.ok, isTrue);
      expect(report.throwIfFailed, returnsNormally);
    });

    test('reports every missing class and resource', () {
      final report = testJvm.preflight(
        classes: {
          'com.example.MissingOne': 'one.jar',
          'java.lang.String': 'the JDK',
          'com.example.MissingTwo': 'two.jar',
        },
        resources: ['META-INF/nope.xml'],
      );

      expect(report.ok, isFalse);
      expect(report.missingClasses, {
        'com.example.MissingOne': 'one.jar',
        'com.example.MissingTwo': 'two.jar',
      });
      expect(report.missingResources, ['META-INF/nope.xml']);
      expect(
        report.throwIfFailed,
        throwsA(
          isA<JniLookupError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('MissingOne (expected from one.jar)'),
              contains('nope.xml'),
            ),
          ),
        ),
      );
    });

    test('a failure on an attached VM points at the foreign class path', () {
      const report = JvmPreflight(
        missingClasses: {'com.example.Missing': 'lib.jar'},
        missingResources: [],
        attached: true,
      );
      expect(report.likelyForeignVm, isTrue);
      expect(
        report.throwIfFailed,
        throwsA(
          isA<JniLookupError>().having(
            (e) => e.message,
            'message',
            contains('did not create'),
          ),
        ),
      );
    });
  });

  test('info reports the running VM', () {
    final info = testJvm.info();
    expect(info.javaVersion, isNotEmpty);
    expect(info.javaHome, isNotEmpty);
    expect(info.classPath, contains('fixtures.jar'));
    expect(info.attached, testJvm.isAttached);
  });

  test('availableFontFamilies lists fonts on a headless VM, and refuses to '
      'hang on a non-headless one on macOS', () {
    final headless = testJvm.systemProperty('java.awt.headless') == 'true';
    if (Platform.isMacOS && !headless) {
      // The suite's VM starts with no options: this is the case that would
      // otherwise hang the runner.
      expect(
        testJvm.availableFontFamilies,
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('headless'),
          ),
        ),
      );
      return;
    }
    // A JDK always ships at least the logical families.
    expect(testJvm.availableFontFamilies(), contains('Dialog'));
  });

  test('enumFor caches one reference per constant', () {
    final first = testJvm.enumFor('java.util.concurrent.TimeUnit', 'SECONDS');
    final second = testJvm.enumFor('java.util.concurrent.TimeUnit', 'SECONDS');
    expect(identical(first, second), isTrue);
    expect(first.javaToString(), 'SECONDS');
    expect(
      testJvm.enumFor('java.util.concurrent.TimeUnit', 'DAYS').javaToString(),
      'DAYS',
    );
  });

  group('java.util.logging', () {
    tearDown(testJvm.configureJavaLogging);

    test('configureJavaLogging sets levels javaLogLevel reads back', () {
      testJvm.configureJavaLogging(
        levels: {'com.example.chatty': 'WARNING'},
        properties: {'com.example.custom': 'yes'},
      );

      expect(testJvm.javaLogLevel('com.example.chatty'), 'WARNING');
      expect(testJvm.javaLogLevel(''), 'INFO');
      expect(testJvm.javaLogLevel('com.example.other'), isNull);
      expect(testJvm.javaLoggingProperty('com.example.custom'), 'yes');
      expect(
        testJvm.javaLoggingProperty('handlers'),
        'java.util.logging.ConsoleHandler',
      );
    });

    test('applies to a logger Java creates afterwards', () async {
      testJvm.configureJavaLogging(levels: {'com.example.later': 'SEVERE'});

      // `Logger.getLogger` is caller-sensitive and fails through JNI; run
      // reflectively on a JVM thread, it has a Java caller. The logger is
      // created now, after the configuration.
      final executor = JavaExecutor.start(testJvm);
      addTearDown(executor.shutdown);
      final loggable = await executor.run(
        testJvm.reflectMethod(
          'java.util.logging.Logger',
          'static java.util.logging.Logger getLogger(String)',
        ),
        ['com.example.later.child'],
        convert: (logger) {
          final level = testJvm.classFor('java.util.logging.Level');
          bool at(String name) => logger!.callJavaAs<bool>(
            'boolean isLoggable(java.util.logging.Level)',
            [level.getJavaStaticField('java.util.logging.Level $name')],
          );
          return (info: at('INFO'), severe: at('SEVERE'));
        },
      );

      expect(loggable.info, isFalse);
      expect(loggable.severe, isTrue);
    });

    test('values survive as written: backslashes and accents', () {
      testJvm.configureJavaLogging(
        properties: {
          'com.example.path': r'C:\logs\app.log',
          'com.example.format': 'Olá — %5\$s%n',
          'com.example.key with=sign': 'yes',
        },
      );
      expect(
        testJvm.javaLoggingProperty('com.example.path'),
        r'C:\logs\app.log',
      );
      expect(
        testJvm.javaLoggingProperty('com.example.format'),
        'Olá — %5\$s%n',
      );
      expect(testJvm.javaLoggingProperty('com.example.key with=sign'), 'yes');
    });
  });

  group('java.time', () {
    test('a local date-time round-trips its fields, to the microsecond', () {
      final value = DateTime(2026, 10, 19, 13, 45, 7, 123, 456);
      final back = testJvm.localFrame(
        () => testJvm.fromJavaTime(testJvm.toJavaLocalDateTime(value)),
        capacity: 8,
      );
      expect(back, value);
      expect(back.isUtc, isFalse);
    });

    test('a LocalDate keeps the day, whatever the time', () {
      final back = testJvm.localFrame(
        () => testJvm.fromJavaTime(
          testJvm.toJavaLocalDate(DateTime(2024, 2, 29, 23, 59)),
        ),
        capacity: 8,
      );
      expect(back, DateTime(2024, 2, 29));
    });

    test('an Instant is the same point in time, as UTC', () {
      final value = DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 1);
      final back = testJvm.localFrame(
        () => testJvm.fromJavaTime(testJvm.toJavaInstant(value)),
        capacity: 8,
      );
      expect(back, value);
      expect(back.isUtc, isTrue);
    });

    test('a ZonedDateTime comes back as its instant', () {
      final back = testJvm.localFrame(() {
        final zoned = testJvm
            .classFor('java.time.ZonedDateTime')
            .callJavaStaticAs<JavaObject>(
              'static java.time.ZonedDateTime parse(CharSequence)',
              ['2026-10-19T10:00:00-03:00[America/Sao_Paulo]'],
            );
        return testJvm.fromJavaTime(zoned);
      }, capacity: 8);
      expect(back, DateTime.utc(2026, 10, 19, 13));
    });

    test('javaToday and javaNow use the JVM clock', () {
      final today = testJvm.javaToday();
      final now = testJvm.javaNow();
      expect(DateTime(now.year, now.month, now.day), today);
    });

    test('wallClockAsUtc keeps every field of a wall-clock value', () {
      // A local 00:30 that day does not exist in São Paulo (spring forward,
      // before 2019): as a local DateTime it would already be 01:30. As UTC
      // fields, in and out, it always exists.
      final value = DateTime.utc(2018, 11, 4, 0, 30);
      final back = testJvm.localFrame(
        () => testJvm.fromJavaTime(
          testJvm.toJavaLocalDateTime(value),
          wallClockAsUtc: true,
        ),
        capacity: 8,
      );
      expect(back, value);
    });

    test('anything else is a JniError', () {
      expect(
        () => testJvm.localFrame(
          () => testJvm.fromJavaTime(
            testJvm.classFor('java.util.ArrayList').newJava('()'),
          ),
          capacity: 8,
        ),
        throwsA(isA<JniError>()),
      );
    });
  });
}
