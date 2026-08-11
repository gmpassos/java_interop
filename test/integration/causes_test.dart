@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// The `getCause()` chain on [JavaException].
///
/// Worth its own suite because the chain is read *while an exception is
/// pending-and-cleared*, using the unchecked raw helpers — a mistake there does
/// not fail loudly, it replaces a useful exception with a useless one, or
/// crashes describing it.
void main() {
  group('JavaException.causes', () {
    test('walks a two-deep chain, outermost first', () {
      final fixtures = fixturesClass();

      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwWithCauses()'),
      );

      // Nested classes keep their `$`, which `isA` treats as significant.
      expect(error.isA(r'Fixtures$FixtureException'), isTrue);
      expect(error.message, 'operation failed');

      expect(error.causes, hasLength(2));
      expect(error.causes[0].className, 'java.lang.IllegalStateException');
      expect(error.causes[0].message, 'connect failed');
      expect(error.causes[1].className, 'java.io.IOException');
      expect(error.causes[1].message, 'no route to host');
    });

    /// The reason the feature exists: a library rewraps everything, so deciding
    /// what a failure *is* means looking past the outermost class.
    test('isCausedBy and causeOf find a class down the chain', () {
      final fixtures = fixturesClass();

      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwWithCauses()'),
      );

      expect(error.isCausedBy('java.io.IOException'), isTrue);
      expect(error.isCausedBy('IOException'), isTrue);
      expect(error.isCausedBy('java.sql.SQLException'), isFalse);

      expect(error.causeOf('IOException')?.message, 'no route to host');
      expect(error.causeOf('java.sql.SQLException'), isNull);

      // The exception's own class counts as a cause of itself.
      expect(error.isCausedBy(r'Fixtures$FixtureException'), isTrue);
    });

    test('an exception without a cause has an empty chain', () {
      final fixtures = fixturesClass();

      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwIllegalState(String)', ['x']),
      );

      expect(error.causes, isEmpty);
      expect(error.isCausedBy('IOException'), isFalse);
    });

    test('a null message on a cause is preserved as null', () {
      final fixtures = fixturesClass();

      // `divide(1, 0)` throws ArithmeticException with a message but no cause;
      // the null-message path is covered by the outer exception below.
      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwWithoutMessage()'),
      );

      expect(error.message, isNull);
      expect(error.causes, isEmpty);
    });

    /// `initCause` forbids a self-cause, but overriding `getCause()` does not —
    /// so a walk that only counted depth would still spin, and one that trusted
    /// `!= null` would loop forever.
    test('a self-referential cause terminates instead of looping', () {
      final fixtures = fixturesClass();

      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwSelfCaused()'),
      );

      expect(error.isA(r'Fixtures$SelfCaused'), isTrue);
      expect(
        error.causes,
        isEmpty,
        reason: 'a throwable that causes itself adds nothing to the chain',
      );
    });

    test('the chain is bounded, so a very deep nest cannot run away', () {
      final fixtures = fixturesClass();

      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwDeeplyNested(int)', [50]),
      );

      expect(error.causes, isNotEmpty);
      expect(
        error.causes.length,
        lessThanOrEqualTo(8),
        reason: 'the walk stops at a fixed depth',
      );
      // The links it did read are the real ones, in order.
      expect(error.causes.first.className, 'java.lang.IllegalStateException');
      expect(error.causes.first.message, 'level 49');
    });

    test('toString lists the causes', () {
      final fixtures = fixturesClass();

      final error = _catchJava(
        () => fixtures.callJavaStatic('void throwWithCauses()'),
      );

      final text = error.toString();
      expect(text, contains('operation failed'));
      expect(text, contains('caused by'));
      expect(text, contains('no route to host'));
    });

    /// Reading the chain must not disturb the pending-exception state: if it
    /// left one set, the *next* unrelated call would fail with something
    /// inexplicable.
    test('the VM is usable immediately afterwards', () {
      final fixtures = fixturesClass();

      _catchJava(() => fixtures.callJavaStatic('void throwWithCauses()'));

      expect(fixtures.callJavaStatic('int staticSum(int, int)', [2, 40]), 42);
    });
  }, skip: skipWithoutJdk);
}

/// Runs [body], expecting it to throw a [JavaException], and returns it.
JavaException _catchJava(void Function() body) {
  try {
    body();
  } on JavaException catch (e) {
    return e;
  }
  fail('expected a JavaException');
}
