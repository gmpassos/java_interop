@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;
  late JavaClass fixtures;

  setUpAll(() => jvm = testJvm);
  setUp(() => fixtures = fixturesClass());

  /// Releases [array] at the end of the test.
  JavaArray keep(JavaArray array) {
    addTearDown(array.release);
    return array;
  }

  /// Calls a static method returning an array, releasing it after the test.
  JavaArray staticArray(String method, String signature) =>
      keep(fixtures.callStatic(method, signature) as JavaArray);

  group('arrays as results', () {
    test('a primitive array arrives as a JavaArray that knows its type', () {
      final array = staticArray('intArray', '()[I');

      expect(array.elementDescriptor, JniType.int_);
      expect(array.descriptor, '[I');
      expect(array.hasPrimitiveElements, isTrue);
      expect(array.length, 3);
    });

    test('every primitive element type reads back', () {
      expect(staticArray('booleanArray', '()[Z').toList(), [true, false, true]);
      expect(staticArray('byteArray', '()[B').toList(), [-128, 0, 127]);
      expect(staticArray('charArray', '()[C').toList(), [
        'a'.codeUnitAt(0),
        'ç'.codeUnitAt(0),
        '中'.codeUnitAt(0),
      ]);
      expect(staticArray('shortArray', '()[S').toList(), [-32768, 0, 32767]);
      expect(staticArray('intArray', '()[I').toList(), [
        -2147483648,
        0,
        2147483647,
      ]);
      expect(staticArray('longArray', '()[J').toList(), [
        -9223372036854775808,
        0,
        9223372036854775807,
      ]);
      expect(staticArray('floatArray', '()[F').toList(), [-1.5, 0.0, 3.5]);
      expect(staticArray('doubleArray', '()[D').toList(), [
        -1.5,
        0.0,
        2.718281828459045,
      ]);
    });

    test('a primitive array keeps its typed-list representation', () {
      expect(staticArray('intArray', '()[I').toList(), isA<Int32List>());
      expect(staticArray('byteArray', '()[B').toList(), isA<Int8List>());
      expect(staticArray('doubleArray', '()[D').toList(), isA<Float64List>());
    });

    test('a String[] reads back as Dart strings, nulls preserved', () {
      expect(staticArray('stringArray', '()[Ljava/lang/String;').toList(), [
        'one',
        null,
        'três',
      ]);
    });

    test('an Integer[] is unboxed element by element', () {
      expect(staticArray('integerArray', '()[Ljava/lang/Integer;').toList(), [
        1,
        null,
        3,
      ]);
    });

    test('a nested array yields JavaArrays that know the inner type', () {
      final outer = staticArray('nestedIntArray', '()[[I');
      expect(outer.elementDescriptor, '[I');
      expect(outer.length, 2);

      final rows = outer.toList().cast<JavaArray>();
      addTearDown(() {
        for (final row in rows) {
          row.release();
        }
      });

      expect(rows[0].elementDescriptor, JniType.int_);
      expect(rows[0].toList(), [1, 2]);
      expect(rows[1].toList(), [3]);
    });

    test('a slice reads only the requested region', () {
      final array = staticArray('intArray', '()[I');
      expect(array.toList(start: 1), [0, 2147483647]);
      expect(array.toList(start: 0, length: 2), [-2147483648, 0]);
    });
  });

  group('arrays as arguments', () {
    test('a Dart List becomes a primitive array', () {
      expect(
        fixtures.callStatic('sumInts', '([I)I', [
          [1, 2, 3],
        ]),
        6,
      );
      expect(
        fixtures.callStatic('sumDoubles', '([D)D', [
          [0.5, 0.25],
        ]),
        0.75,
      );
      expect(
        fixtures.callStatic('describeBytes', '([B)Ljava/lang/String;', [
          [-1, 0, 1],
        ]),
        '[-1, 0, 1]',
      );
    });

    test('an int is widened for a float or double array', () {
      expect(
        fixtures.callStatic('sumDoubles', '([D)D', [
          [1, 2],
        ]),
        3.0,
      );
    });

    test('a Dart List of strings becomes a String[]', () {
      expect(
        fixtures.callStatic(
          'joinStrings',
          '([Ljava/lang/String;)'
              'Ljava/lang/String;',
          [
            ['a', 'b', 'c'],
          ],
        ),
        'a,b,c',
      );
    });

    test('a nested Dart List becomes int[][]', () {
      expect(
        fixtures.callStatic('sumNested', '([[I)I', [
          [
            [1, 2],
            [3],
          ],
        ]),
        6,
      );
    });

    test('an empty list becomes a zero-length array', () {
      expect(fixtures.callStatic('sumInts', '([I)I', [<int>[]]), 0);
    });

    test('a JavaArray can be passed straight back in', () {
      final array = JavaArray.ofInts(jvm, [10, 20]);
      addTearDown(array.release);

      expect(fixtures.callStatic('sumInts', '([I)I', [array]), 30);
      // Still usable afterwards: passing it does not consume it.
      expect(fixtures.callStatic('sumInts', '([I)I', [array]), 30);
    });

    test('an array result feeds back into another call', () {
      final array = staticArray('intArray', '()[I');
      expect(fixtures.callStatic('sumInts', '([I)I', [array]), -1);
    });

    test('an instance method takes an array too', () {
      final instance = fixtures.newInstance('(Ljava/lang/String;I)V', [
        'x',
        100,
      ]);
      addTearDown(instance.release);

      expect(
        instance.call('sumWithNumber', '([I)I', [
          [1, 2],
        ]),
        103,
      );
    });

    test('null passes as a null array', () {
      expect(
        () => fixtures.callStatic('sumInts', '([I)I', [null]),
        throwsA(isA<JavaException>()),
        reason: 'Java dereferences it and throws NullPointerException',
      );
    });
  });

  group('building arrays', () {
    test('the typed factories build the right element type', () {
      expect(keep(JavaArray.ofBooleans(jvm, [true])).toList(), [true]);
      expect(keep(JavaArray.ofBytes(jvm, [-1])).toList(), [-1]);
      expect(keep(JavaArray.ofChars(jvm, [65])).toList(), [65]);
      expect(keep(JavaArray.ofShorts(jvm, [-2])).toList(), [-2]);
      expect(keep(JavaArray.ofInts(jvm, [3])).toList(), [3]);
      expect(keep(JavaArray.ofLongs(jvm, [4])).toList(), [4]);
      expect(keep(JavaArray.ofFloats(jvm, [1.5])).toList(), [1.5]);
      expect(keep(JavaArray.ofDoubles(jvm, [2.5])).toList(), [2.5]);
      expect(keep(JavaArray.ofStrings(jvm, ['a', null])).toList(), ['a', null]);
    });

    test('sized creates a zero-filled primitive array', () {
      final array = JavaArray.sized(jvm, JniType.int_, 3);
      addTearDown(array.release);

      expect(array.length, 3);
      expect(array.toList(), [0, 0, 0]);
    });

    test('sized creates a null-filled object array', () {
      final array = JavaArray.sized(jvm, JniType.string, 2);
      addTearDown(array.release);

      expect(array.toList(), [null, null]);
    });

    test('ofObjects boxes the elements it is given', () {
      final array = keep(
        JavaArray.ofObjects(jvm, 'java.lang.Object', ['text', 7, null]),
      );
      expect(array.length, 3);

      final boxed = autoReleaseObject(array[1] as JavaObject);
      expect(
        fixtures.callStatic(
          'classOf',
          '(Ljava/lang/Object;)Ljava/lang/String;',
          [boxed],
        ),
        'java.lang.Integer',
      );
      expect(boxed.toDart(), 7);
    });
  });

  group('element access', () {
    test('reads and writes a primitive element', () {
      final array = JavaArray.ofInts(jvm, [1, 2, 3]);
      addTearDown(array.release);

      expect(array[1], 2);
      array[1] = 20;
      expect(array[1], 20);
      expect(array.toList(), [1, 20, 3]);
    });

    test('reads and writes a String element', () {
      final array = JavaArray.ofStrings(jvm, ['a', 'b']);
      addTearDown(array.release);

      expect(array[0], 'a');
      array[0] = 'z';
      array[1] = null;
      expect(array.toList(), ['z', null]);
    });

    test('an out-of-range index raises the Java exception', () {
      final array = JavaArray.ofInts(jvm, [1]);
      addTearDown(array.release);

      expect(() => array[5], throwsA(isA<JniError>()));
    });

    /// The element type and the length, which is what one wants to see in a log
    /// line or a failed expectation — a bare `JavaRef` handle tells neither.
    test('toString carries the element type and the length', () {
      final array = JavaArray.ofInts(jvm, [1, 2, 3]);
      addTearDown(array.release);
      expect(array.toString(), 'JavaArray([I[3])');

      final strings = JavaArray.ofStrings(jvm, ['a']);
      addTearDown(strings.release);
      expect(strings.toString(), 'JavaArray([Ljava/lang/String;[1])');
    });
  });

  group('array fields', () {
    test('reads an array field', () {
      final instance = fixturesInstance(fixtures);
      final field = instance.getField('intArrayField', '[I') as JavaArray;
      addTearDown(field.release);

      expect(field.toList(), [1, 2, 3]);
    });

    test('writes an array field from a Dart List', () {
      final instance = fixturesInstance(fixtures);
      instance.setField('intArrayField', '[I', [9, 8]);

      final field = instance.getField('intArrayField', '[I') as JavaArray;
      addTearDown(field.release);
      expect(field.toList(), [9, 8]);
    });
  });

  group('errors', () {
    test('a List for a non-array parameter is rejected', () {
      expect(
        () => fixtures.callStatic(
          'echoString',
          '(Ljava/lang/String;)'
              'Ljava/lang/String;',
          [
            ['a'],
          ],
        ),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('not an array type'),
          ),
        ),
      );
    });

    test('a wrong element type is reported with its index', () {
      expect(
        () => fixtures.callStatic('sumInts', '([I)I', [
          [1, 'two'],
        ]),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('element 1'),
          ),
        ),
      );
    });

    test('null cannot be stored in a primitive array', () {
      final array = JavaArray.ofInts(jvm, [1]);
      addTearDown(array.release);

      expect(() => array[0] = null, throwsA(isA<JniError>()));
    });
  });
}
