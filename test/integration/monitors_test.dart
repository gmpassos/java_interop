@TestOn('vm')
library;

import 'dart:ffi';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Monitors and reference-type reporting.
void main() {
  group('synchronized', () {
    test('runs the body and returns its value', () {
      final list = autoReleaseObject(
        testJvm.classFor('java.util.ArrayList').newJava('()'),
      );

      final size = testJvm.synchronized(list, () {
        list.callJava('boolean add(Object)', ['a']);
        list.callJava('boolean add(Object)', ['b']);
        return list.callJava('int size()');
      });

      expect(size, 2);
    });

    /// Java's monitors are reentrant, and code that locks in a loop or through a
    /// callback depends on it.
    test('the same thread may enter twice', () {
      final target = autoReleaseObject(
        testJvm.classFor('java.lang.Object').newJava('()'),
      );

      expect(
        testJvm.synchronized(
          target,
          () => testJvm.synchronized(target, () => 'nested'),
        ),
        'nested',
      );
    });

    test('the monitor is released when the body throws', () {
      final target = autoReleaseObject(
        testJvm.classFor('java.lang.Object').newJava('()'),
      );

      expect(
        () => testJvm.synchronized(target, () => throw StateError('boom')),
        throwsStateError,
      );

      // Still lockable, which it would not be if the exit had been skipped.
      expect(testJvm.synchronized(target, () => 'again'), 'again');
    });

    test(
      'a class object can be locked, as `synchronized` on a static does',
      () {
        final clazz = testJvm.classFor('com.nfeflash.example.Fixtures');
        expect(
          testJvm.synchronized(
            clazz,
            () => clazz.callJavaStatic('int staticSum(int, int)', [2, 40]),
          ),
          42,
        );
      },
    );

    test('a null reference is refused', () {
      final nothing = JavaObject(
        testJvm,
        JavaRef(testJvm, nullptr, JavaRefKind.local),
      );
      expect(
        () => testJvm.synchronized(nothing, () {}),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('null reference'),
          ),
        ),
      );
    });

    test('something that is not a reference is refused', () {
      expect(
        () => testJvm.synchronized('a Dart string', () {}),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('not a Java reference'),
          ),
        ),
      );
    });
  }, skip: skipWithoutJdk);

  group('refTypeOf', () {
    test('tells a local from a global', () {
      final local = autoRelease(testJvm.findClass('java.lang.Object'));
      expect(testJvm.refTypeOf(local), JavaRefTypeReport.local);

      final global = autoRelease(local.toGlobal());
      expect(testJvm.refTypeOf(global), JavaRefTypeReport.global);
    });

    /// The reason it is worth having: the VM disagreeing with this library's
    /// bookkeeping is exactly the bug that is otherwise invisible.
    test('reports a released reference as invalid', () {
      final ref = testJvm.findClass('java.lang.Object').toGlobal();
      expect(testJvm.refTypeOf(ref), JavaRefTypeReport.global);

      ref.release();
      expect(
        () => testJvm.refTypeOf(ref),
        throwsA(isA<JniError>()),
        reason: 'this package refuses to hand a released handle to the VM',
      );
    });

    test('a null reference is invalid, not local', () {
      expect(
        testJvm.refTypeOf(JavaRef(testJvm, nullptr, JavaRefKind.local)),
        JavaRefTypeReport.invalid,
      );
    });
  }, skip: skipWithoutJdk);
}
