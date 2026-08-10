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

  /// Calls a static fixture method returning an array and hands back the ref.
  JavaRef arrayFrom(String method, String signature) {
    final result = fixtures.callStatic(method, signature) as JavaObject;
    addTearDown(result.release);
    return result.ref;
  }

  group('reading primitive arrays from Java', () {
    test('boolean[]', () {
      final array = arrayFrom('booleanArray', '()[Z');
      expect(jvm.arrayLength(array), 3);
      expect(jvm.getBooleanArray(array), [true, false, true]);
    });

    test('byte[] keeps signs', () {
      final array = arrayFrom('byteArray', '()[B');
      expect(jvm.getByteArray(array), [-128, 0, 127]);
    });

    test('char[] is unsigned UTF-16', () {
      final array = arrayFrom('charArray', '()[C');
      expect(jvm.getCharArray(array), [0x61, 0x00E7, 0x4E2D]);
      expect(String.fromCharCodes(jvm.getCharArray(array)), 'aç中');
    });

    test('short[] keeps signs', () {
      final array = arrayFrom('shortArray', '()[S');
      expect(jvm.getShortArray(array), [-32768, 0, 32767]);
    });

    test('int[]', () {
      final array = arrayFrom('intArray', '()[I');
      expect(jvm.getIntArray(array), [-2147483648, 0, 2147483647]);
    });

    test('long[] carries the full 64-bit range', () {
      final array = arrayFrom('longArray', '()[J');
      expect(jvm.getLongArray(array), [
        -9223372036854775808,
        0,
        9223372036854775807,
      ]);
    });

    test('float[]', () {
      final array = arrayFrom('floatArray', '()[F');
      expect(jvm.getFloatArray(array), [-1.5, 0.0, 3.5]);
    });

    test('double[] keeps full precision', () {
      final array = arrayFrom('doubleArray', '()[D');
      expect(jvm.getDoubleArray(array), [-1.5, 0.0, 2.718281828459045]);
    });
  });

  group('array regions', () {
    test('a sub-range can be read', () {
      final array = arrayFrom('intArray', '()[I');

      expect(jvm.getIntArray(array, start: 1), [0, 2147483647]);
      expect(jvm.getIntArray(array, start: 0, length: 2), [-2147483648, 0]);
      expect(jvm.getIntArray(array, start: 1, length: 1), [0]);
      expect(jvm.getIntArray(array, start: 3), isEmpty);
    });

    test('an out-of-range region is rejected before reaching the VM', () {
      final array = arrayFrom('intArray', '()[I');

      expect(
        () => jvm.getIntArray(array, start: 0, length: 4),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('outside an array of length 3'),
          ),
        ),
      );
      expect(() => jvm.getIntArray(array, start: 4), throwsA(isA<JniError>()));
      expect(
        () => jvm.getIntArray(array, start: -1),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('negative array start'),
          ),
        ),
      );
    });
  });

  group('creating and writing primitive arrays', () {
    test('int[] round-trips through Java', () {
      final array = autoRelease(jvm.newIntArray(4));
      expect(jvm.arrayLength(array), 4);
      expect(jvm.getIntArray(array), [0, 0, 0, 0], reason: 'zero-initialised');

      jvm.setIntArray(array, [1, 2, 3, 4]);
      expect(jvm.getIntArray(array), [1, 2, 3, 4]);

      // Hand it back to Java to prove the VM sees the same contents.
      expect(fixtures.callStatic('sumInts', '([I)I', [array]), 10);
    });

    test('a partial write leaves the rest untouched', () {
      final array = autoRelease(jvm.newIntArray(4));
      jvm.setIntArray(array, [7, 8], start: 1);
      expect(jvm.getIntArray(array), [0, 7, 8, 0]);
    });

    test('byte[] round-trips, signs intact', () {
      final array = autoRelease(jvm.newByteArray(3));
      jvm.setByteArray(array, [-128, 0, 127]);

      expect(jvm.getByteArray(array), [-128, 0, 127]);
      expect(
        fixtures.callStatic('describeBytes', '([B)Ljava/lang/String;', [array]),
        '[-128, 0, 127]',
      );
    });

    test('double[] round-trips and sums in Java', () {
      final array = autoRelease(jvm.newDoubleArray(3));
      jvm.setDoubleArray(array, [1.5, 2.25, -0.75]);

      expect(jvm.getDoubleArray(array), [1.5, 2.25, -0.75]);
      expect(fixtures.callStatic('sumDoubles', '([D)D', [array]), 3.0);
    });

    test('every primitive array type can be created and read back', () {
      expect(jvm.getBooleanArray(autoRelease(jvm.newBooleanArray(2))), [
        false,
        false,
      ]);
      expect(jvm.getByteArray(autoRelease(jvm.newByteArray(2))), [0, 0]);
      expect(jvm.getCharArray(autoRelease(jvm.newCharArray(2))), [0, 0]);
      expect(jvm.getShortArray(autoRelease(jvm.newShortArray(2))), [0, 0]);
      expect(jvm.getIntArray(autoRelease(jvm.newIntArray(2))), [0, 0]);
      expect(jvm.getLongArray(autoRelease(jvm.newLongArray(2))), [0, 0]);
      expect(jvm.getFloatArray(autoRelease(jvm.newFloatArray(2))), [0.0, 0.0]);
      expect(jvm.getDoubleArray(autoRelease(jvm.newDoubleArray(2))), [
        0.0,
        0.0,
      ]);
    });

    test('newPrimitiveArray dispatches on the descriptor', () {
      final ints = autoRelease(jvm.newPrimitiveArray(JniType.int_, 3));
      expect(jvm.arrayLength(ints), 3);
      expect(jvm.getIntArray(ints), [0, 0, 0]);

      expect(
        () => jvm.newPrimitiveArray(JniType.string, 1),
        throwsA(isA<JniError>()),
      );
      expect(
        () => jvm.newPrimitiveArray(JniType.void_, 1),
        throwsA(isA<JniError>()),
      );
    });

    test('a zero-length array is valid', () {
      final empty = autoRelease(jvm.newIntArray(0));
      expect(jvm.arrayLength(empty), 0);
      expect(jvm.getIntArray(empty), isEmpty);
      expect(fixtures.callStatic('sumInts', '([I)I', [empty]), 0);
    });

    test('a negative length is rejected', () {
      expect(
        () => jvm.newIntArray(-1),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('negative array length'),
          ),
        ),
      );
    });

    test('writing an empty list is a no-op', () {
      final array = autoRelease(jvm.newIntArray(2));
      jvm.setIntArray(array, const []);
      expect(jvm.getIntArray(array), [0, 0]);
    });
  });

  group('object arrays', () {
    test('reading a String[] from Java, including a null element', () {
      final array = arrayFrom('stringArray', '()[Ljava/lang/String;');
      expect(jvm.arrayLength(array), 3);

      final first = autoRelease(jvm.getObjectArrayElement(array, 0));
      final second = autoRelease(jvm.getObjectArrayElement(array, 1));
      final third = autoRelease(jvm.getObjectArrayElement(array, 2));

      expect(jvm.stringFrom(first), 'one');
      expect(second.isNull, isTrue, reason: 'a null element stays null');
      expect(jvm.stringFrom(second), isNull);
      expect(jvm.stringFrom(third), 'três');
    });

    test('creating and filling a String[]', () {
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final array = autoRelease(jvm.newObjectArray(3, stringClass));

      expect(jvm.arrayLength(array), 3);
      expect(
        autoRelease(jvm.getObjectArrayElement(array, 0)).isNull,
        isTrue,
        reason: 'elements start as null',
      );

      jvm.setObjectArrayElement(array, 0, autoRelease(jvm.newString('a')));
      jvm.setObjectArrayElement(array, 1, autoRelease(jvm.newString('b')));
      jvm.setObjectArrayElement(array, 2, autoRelease(jvm.newString('c')));

      expect(
        fixtures.callStatic(
          'joinStrings',
          '([Ljava/lang/String;)Ljava/lang/String;',
          [array],
        ),
        'a,b,c',
      );
    });

    test('an initial element fills every slot', () {
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final filler = autoRelease(jvm.newString('x'));
      final array = autoRelease(jvm.newObjectArray(3, stringClass, filler));

      expect(
        fixtures.callStatic(
          'joinStrings',
          '([Ljava/lang/String;)Ljava/lang/String;',
          [array],
        ),
        'x,x,x',
      );
    });

    test('an element can be set back to null', () {
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final filler = autoRelease(jvm.newString('x'));
      final array = autoRelease(jvm.newObjectArray(2, stringClass, filler));

      jvm.setObjectArrayElement(array, 0, null);
      expect(autoRelease(jvm.getObjectArrayElement(array, 0)).isNull, isTrue);
    });

    test('an out-of-bounds index surfaces the Java exception', () {
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final array = autoRelease(jvm.newObjectArray(2, stringClass));

      expect(
        () => jvm.getObjectArrayElement(array, 5),
        throwsA(
          isA<JavaException>().having(
            (e) => e.isA('ArrayIndexOutOfBoundsException'),
            'is ArrayIndexOutOfBoundsException',
            isTrue,
          ),
        ),
      );
    });

    test('an array is an Object, so it can be passed as one', () {
      final array = autoRelease(jvm.newIntArray(2));
      final objectClass = autoRelease(jvm.findClass('java.lang.Object'));

      expect(jvm.isInstanceOf(array, objectClass), isTrue);
    });
  });
}
