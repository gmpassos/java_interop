@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

void main() {
  group('JValue integral packing', () {
    test('booleans use JNI_TRUE / JNI_FALSE', () {
      expect(JValue.fromBool(true).bits, 1);
      expect(JValue.fromBool(false).bits, 0);
    });

    test('integers are stored verbatim in the low bytes', () {
      expect(JValue.fromInt(0).bits, 0);
      expect(JValue.fromInt(42).bits, 42);
      expect(JValue.fromInt(-1).bits, -1);
      expect(JValue.fromInt(0x7fffffffffffffff).bits, 0x7fffffffffffffff);
    });

    test('a null reference is the zero slot', () {
      expect(JValue.nullReference.bits, 0);
      expect(JValue.fromPointer(nullptr).bits, 0);
    });

    test('a pointer is stored as its address', () {
      final pointer = Pointer<Void>.fromAddress(0xdeadbeef);
      expect(JValue.fromPointer(pointer).bits, 0xdeadbeef);
    });
  });

  group('JValue floating-point packing', () {
    // The bit patterns are what JNI actually reads out of the union, so they
    // are asserted directly rather than round-tripped through the same helper.
    test('a float occupies the low 4 bytes as IEEE-754', () {
      // 1.0f == 0x3F800000
      expect(JValue.fromFloat(1.0).bits & 0xFFFFFFFF, 0x3F800000);
      // -2.0f == 0xC0000000
      expect(JValue.fromFloat(-2.0).bits & 0xFFFFFFFF, 0xC0000000);
      expect(JValue.fromFloat(0.0).bits, 0);
    });

    test('a double occupies all 8 bytes as IEEE-754', () {
      // 1.0 == 0x3FF0000000000000
      expect(JValue.fromDouble(1.0).bits, 0x3FF0000000000000);
      expect(JValue.fromDouble(0.0).bits, 0);
    });

    test('float and double patterns differ for the same value', () {
      // The reason a signature is needed to coerce a Dart double: writing the
      // wrong width silently produces a different number in Java.
      expect(JValue.fromFloat(3.5).bits, isNot(JValue.fromDouble(3.5).bits));
    });

    test('bit readers invert the writers', () {
      expect(floatFromBits(JValue.fromFloat(3.5).bits), 3.5);
      expect(
        doubleFromBits(JValue.fromDouble(2.718281828459045).bits),
        2.718281828459045,
      );

      // A float cannot hold full double precision; the value is the nearest
      // float, which is what Java would see too.
      expect(
        floatFromBits(JValue.fromFloat(0.1).bits),
        (ByteData(4)..setFloat32(0, 0.1)).getFloat32(0),
      );
    });

    test('special values survive', () {
      expect(
        doubleFromBits(JValue.fromDouble(double.infinity).bits),
        double.infinity,
      );
      expect(
        doubleFromBits(JValue.fromDouble(double.negativeInfinity).bits),
        double.negativeInfinity,
      );
      expect(doubleFromBits(JValue.fromDouble(double.nan).bits).isNaN, isTrue);
      expect(
        floatFromBits(JValue.fromFloat(double.infinity).bits),
        double.infinity,
      );
    });
  });

  group('JValue.forDescriptor', () {
    test('coerces each primitive from its natural Dart type', () {
      expect(JValue.forDescriptor(JniType.boolean, true).bits, 1);
      expect(JValue.forDescriptor(JniType.byte, -128).bits, -128);
      expect(JValue.forDescriptor(JniType.char, 0x00E7).bits, 0x00E7);
      expect(JValue.forDescriptor(JniType.short, -32768).bits, -32768);
      expect(JValue.forDescriptor(JniType.int_, 123456).bits, 123456);
      expect(JValue.forDescriptor(JniType.long, 1 << 40).bits, 1 << 40);
      expect(
        JValue.forDescriptor(JniType.float, 1.0).bits & 0xFFFFFFFF,
        0x3F800000,
      );
      expect(
        JValue.forDescriptor(JniType.double_, 1.0).bits,
        0x3FF0000000000000,
      );
    });

    test('accepts an int where a float or double is declared', () {
      // Dart writes `1` where Java wants `1.0f` often enough that rejecting it
      // would be hostile; the conversion is exact.
      expect(
        JValue.forDescriptor(JniType.float, 1).bits & 0xFFFFFFFF,
        0x3F800000,
      );
      expect(JValue.forDescriptor(JniType.double_, 1).bits, 0x3FF0000000000000);
    });

    test('accepts null and pointers for reference parameters', () {
      expect(JValue.forDescriptor(JniType.string, null).bits, 0);
      expect(JValue.forDescriptor('[I', null).bits, 0);
      expect(
        JValue.forDescriptor(
          JniType.string,
          Pointer<Void>.fromAddress(0x10),
        ).bits,
        0x10,
      );
    });

    test(
      'rejects mismatched Dart types with a message naming the parameter',
      () {
        void expectRejected(String descriptor, Object? value, String reason) {
          expect(
            () => JValue.forDescriptor(descriptor, value),
            throwsA(
              isA<JniError>().having(
                (e) => e.message,
                'message',
                contains(reason),
              ),
            ),
            reason: '$descriptor <- $value',
          );
        }

        expectRejected(JniType.boolean, 1, 'expected a bool');
        expectRejected(JniType.int_, 'x', 'expected an int');
        expectRejected(JniType.int_, 1.5, 'expected an int');
        expectRejected(JniType.double_, 'x', 'expected a double');
        expectRejected(JniType.string, 'a Dart string', 'expected a Pointer');
        expectRejected(JniType.void_, null, 'not a valid parameter type');
        expectRejected('Q', 1, 'unknown parameter descriptor');
      },
    );

    test('toString shows the raw slot in hex', () {
      expect(JValue.fromInt(255).toString(), 'JValue(0xff)');
    });
  });
}
