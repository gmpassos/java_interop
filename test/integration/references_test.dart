@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;

  setUpAll(() => jvm = testJvm);

  group('local references', () {
    test('a fresh reference is local and not null', () {
      final ref = autoRelease(jvm.newString('hello'));

      expect(ref.kind, JavaRefKind.local);
      expect(ref.isNull, isFalse);
      expect(ref.isReleased, isFalse);
      expect(ref.toString(), startsWith('JavaRef(local, 0x'));
    });

    test('release is idempotent', () {
      final ref = jvm.newString('hello');

      ref.release();
      expect(ref.isReleased, isTrue);
      expect(
        ref.release,
        returnsNormally,
        reason: 'a second release is a no-op',
      );
    });

    test('use after release throws instead of passing a dangling pointer', () {
      // The alternative is handing the VM freed memory, which crashes the
      // process somewhere unrelated and much later.
      final ref = jvm.newString('hello');
      ref.release();

      expect(
        () => ref.pointer,
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('after release()'),
          ),
        ),
      );
      expect(() => jvm.stringFrom(ref), throwsA(isA<JniError>()));
      expect(ref.toString(), 'JavaRef(released)');
    });

    test('a released reference reports isNull as false, not true', () {
      // isNull means "wraps Java null", which is different from "released".
      final ref = jvm.newString('hello');
      ref.release();
      expect(ref.isNull, isFalse);
      expect(ref.isReleased, isTrue);
    });

    test('toLocal creates an independent handle to the same object', () {
      final original = autoRelease(jvm.newString('hello'));
      final copy = autoRelease(original.toLocal());

      expect(copy.kind, JavaRefKind.local);
      expect(copy.isSameObject(original), isTrue);

      copy.release();
      // Releasing the copy must not invalidate the original.
      expect(jvm.stringFrom(original), 'hello');
    });
  });

  group('global references', () {
    test('toGlobal promotes without consuming the original', () {
      final local = autoRelease(jvm.newString('hello'));
      final global = autoRelease(local.toGlobal());

      expect(global.kind, JavaRefKind.global);
      expect(global.isSameObject(local), isTrue);
      expect(jvm.stringFrom(global), 'hello');
      expect(jvm.stringFrom(local), 'hello', reason: 'original still valid');
    });

    test('a global survives a local frame that would free a local', () {
      late JavaRef global;

      jvm.localFrame(() {
        final local = jvm.newString('kept');
        global = local.toGlobal();
      });

      // The local is gone with the frame; the global is still readable.
      addTearDown(global.release);
      expect(jvm.stringFrom(global), 'kept');
    });

    test('a global is usable from another isolate (another thread)', () async {
      final global = jvm.newString('shared').toGlobal();
      addTearDown(global.release);

      final address = global.pointer.address;
      final jar = fixturesJarPath;

      final read = await Isolate.run(() {
        final other = Jvm.startOrAttach(classPath: [jar]);
        // Rebuild the handle from the raw address: a global reference is valid
        // on any thread, which is exactly what distinguishes it from a local.
        final ref = JavaRef(
          other,
          Pointer<Void>.fromAddress(address),
          JavaRefKind.global,
        );
        return other.stringFrom(ref);
      });

      expect(read, 'shared');
    });

    test('releasing a global deletes it', () {
      final global = jvm.newString('x').toGlobal();
      global.release();
      expect(global.isReleased, isTrue);
      expect(() => global.pointer, throwsA(isA<JniError>()));
    });
  });

  group('identity', () {
    test('isSameObject is reference identity, not equals', () {
      final a = autoRelease(jvm.newString('same'));
      final b = autoRelease(jvm.newString('same'));

      // Two distinct String objects with equal contents.
      expect(a.isSameObject(b), isFalse);

      final aObject = JavaObject(jvm, a);
      final bObject = JavaObject(jvm, b);
      expect(
        aObject.javaEquals(bObject),
        isTrue,
        reason: 'equals compares contents',
      );
    });

    test('a reference is the same object as itself', () {
      final ref = autoRelease(jvm.newString('x'));
      expect(ref.isSameObject(ref), isTrue);
    });
  });

  group('local frames', () {
    test('frees the locals created inside', () {
      final result = jvm.localFrame(() {
        var total = 0;
        for (var i = 0; i < 200; i++) {
          final string = jvm.newString('value $i');
          total += jvm.stringLength(string);
          // Deliberately not released: the frame is what reclaims them.
        }
        return total;
      });

      expect(result, greaterThan(0));
    });

    test('returns the body result', () {
      expect(jvm.localFrame(() => 42), 42);
      expect(jvm.localFrame(() => 'text'), 'text');
    });

    test('pops the frame even when the body throws', () {
      expect(
        () => jvm.localFrame<void>(() => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );

      // The frame stack must be balanced, or every later call misbehaves.
      expect(jvm.stringFrom(autoRelease(jvm.newString('after'))), 'after');
    });

    test('frames nest', () {
      final result = jvm.localFrame(() {
        final outer = jvm.newString('outer');
        final inner = jvm.localFrame(() {
          jvm.newString('inner');
          return jvm.stringFrom(outer);
        });
        return inner;
      });

      expect(result, 'outer');
    });

    test('many frames in sequence do not exhaust the reference table', () {
      // The failure mode this guards against is a slow leak: without frames,
      // 20k locals would overflow the default table.
      for (var i = 0; i < 200; i++) {
        jvm.localFrame(() {
          for (var j = 0; j < 100; j++) {
            jvm.newString('leak $i-$j');
          }
        });
      }

      expect(
        jvm.stringFrom(autoRelease(jvm.newString('still here'))),
        'still here',
      );
    });

    test('ensureLocalCapacity accepts a hint', () {
      expect(() => jvm.ensureLocalCapacity(64), returnsNormally);
    });
  });
}
