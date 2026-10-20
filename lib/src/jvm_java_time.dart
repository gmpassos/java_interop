/// `DateTime` to and from `java.time`.
library;

import 'errors.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'jvm.dart';
import 'jvm_diagnostics.dart';

/// Conversions between Dart's [DateTime] and `java.time`.
///
/// Dart has one type for both a wall-clock time and an instant, told apart by
/// [DateTime.isUtc]; `java.time` has a type for each. The rule here:
///
/// * `LocalDate` and `LocalDateTime` are wall-clock values: their fields are
///   read from, and come back as, a *local* [DateTime] — the same year, month,
///   day, hour, … with no zone conversion, whatever the host's or the JVM's
///   zone is.
/// * `Instant`, `ZonedDateTime` and `OffsetDateTime` are points in time: they
///   come back as a UTC [DateTime] for the same instant.
///
/// Objects returned are local references: create them inside a
/// [JvmLocalFrames.localFrame] or release them.
extension JvmJavaTime on Jvm {
  /// A `java.time.LocalDate` with [date]'s year, month and day.
  JavaObject toJavaLocalDate(DateTime date) =>
      classFor('java.time.LocalDate').callJavaStaticAs<JavaObject>(
        'static java.time.LocalDate of(int, int, int)',
        [date.year, date.month, date.day],
      );

  /// A `java.time.LocalDateTime` with [dateTime]'s fields, to the microsecond.
  JavaObject toJavaLocalDateTime(DateTime dateTime) =>
      classFor('java.time.LocalDateTime').callJavaStaticAs<JavaObject>(
        'static java.time.LocalDateTime of(int, int, int, int, int, int, int)',
        [
          dateTime.year,
          dateTime.month,
          dateTime.day,
          dateTime.hour,
          dateTime.minute,
          dateTime.second,
          dateTime.millisecond * 1000000 + dateTime.microsecond * 1000,
        ],
      );

  /// A `java.time.Instant` for the instant [dateTime] is, local or UTC.
  JavaObject toJavaInstant(DateTime dateTime) {
    final micros = dateTime.microsecondsSinceEpoch;
    final seconds = micros ~/ 1000000;
    final nanos = (micros - seconds * 1000000) * 1000;
    return classFor('java.time.Instant').callJavaStaticAs<JavaObject>(
      'static java.time.Instant ofEpochSecond(long, long)',
      [seconds, nanos],
    );
  }

  /// [value] — a `LocalDate`, `LocalDateTime`, `Instant`, `ZonedDateTime` or
  /// `OffsetDateTime` — as a [DateTime], by the rule above. Nanoseconds are
  /// truncated to microseconds, Dart's precision.
  DateTime fromJavaTime(JavaObject value) {
    if (value.isInstanceOf(classFor('java.time.LocalDate'))) {
      return DateTime(
        value.callJavaAs<int>('int getYear()'),
        value.callJavaAs<int>('int getMonthValue()'),
        value.callJavaAs<int>('int getDayOfMonth()'),
      );
    }
    if (value.isInstanceOf(classFor('java.time.LocalDateTime'))) {
      final nano = value.callJavaAs<int>('int getNano()');
      return DateTime(
        value.callJavaAs<int>('int getYear()'),
        value.callJavaAs<int>('int getMonthValue()'),
        value.callJavaAs<int>('int getDayOfMonth()'),
        value.callJavaAs<int>('int getHour()'),
        value.callJavaAs<int>('int getMinute()'),
        value.callJavaAs<int>('int getSecond()'),
        nano ~/ 1000000,
        (nano ~/ 1000) % 1000,
      );
    }
    if (value.isInstanceOf(classFor('java.time.Instant'))) {
      return _fromInstant(value);
    }
    if (value.isInstanceOf(classFor('java.time.ZonedDateTime')) ||
        value.isInstanceOf(classFor('java.time.OffsetDateTime'))) {
      final instant = value.callJavaAs<JavaObject>(
        'java.time.Instant toInstant()',
      );
      try {
        return _fromInstant(instant);
      } finally {
        instant.release();
      }
    }
    throw JniError(
      'not a java.time date or time: ${value.javaToString()}; expected a '
      'LocalDate, LocalDateTime, Instant, ZonedDateTime or OffsetDateTime',
    );
  }

  /// Today, in the JVM's default zone (`-Duser.timezone`), which need not be
  /// the host's — the date Java code calling `LocalDate.now()` sees.
  DateTime javaToday() => localFrame(
    () => fromJavaTime(
      classFor(
        'java.time.LocalDate',
      ).callJavaStaticAs<JavaObject>('static java.time.LocalDate now()'),
    ),
    capacity: 8,
  );

  /// The wall-clock time in the JVM's default zone, as a local [DateTime] —
  /// what Java code calling `LocalDateTime.now()` sees.
  DateTime javaNow() => localFrame(
    () => fromJavaTime(
      classFor(
        'java.time.LocalDateTime',
      ).callJavaStaticAs<JavaObject>('static java.time.LocalDateTime now()'),
    ),
    capacity: 8,
  );

  DateTime _fromInstant(JavaObject instant) {
    final seconds = instant.callJavaAs<int>('long getEpochSecond()');
    final nano = instant.callJavaAs<int>('int getNano()');
    return DateTime.fromMicrosecondsSinceEpoch(
      seconds * 1000000 + nano ~/ 1000,
      isUtc: true,
    );
  }
}
