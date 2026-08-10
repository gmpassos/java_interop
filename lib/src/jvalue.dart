/// One slot of a JNI `jvalue[]` argument array.
///
/// `jvalue` is an 8-byte union:
///
/// ```c
/// typedef union jvalue {
///     jboolean z; jbyte b; jchar c; jshort s;
///     jint i; jlong j; jfloat f; jdouble d; jobject l;
/// } jvalue;
/// ```
///
/// The `A` call variants read whichever member the *declared* parameter type
/// names, so each argument only has to occupy the right bytes of its slot. On a
/// little-endian 64-bit target every integral and reference member lives in the
/// low bytes, which is why they can all be staged through an `int`. Floats are
/// the exception: `jfloat` is a 4-byte IEEE-754 value, so its *bit pattern* —
/// not its numeric value — has to land in the low 4 bytes.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'errors.dart';
import 'signatures.dart';

/// A single JNI argument, staged as the raw 64 bits of its `jvalue` slot.
class JValue {
  const JValue._(this.bits);

  /// The raw contents of the 8-byte union slot.
  final int bits;

  /// A `jboolean` (`Z`). JNI defines `JNI_TRUE` as 1 and `JNI_FALSE` as 0.
  factory JValue.fromBool(bool value) => JValue._(value ? 1 : 0);

  /// A `jbyte`, `jchar`, `jshort`, `jint` or `jlong` (`B`, `C`, `S`, `I`, `J`).
  ///
  /// Narrower types simply ignore the high bytes, so one constructor covers
  /// all five.
  factory JValue.fromInt(int value) => JValue._(value);

  /// A `jfloat` (`F`), written as its 32-bit IEEE-754 bit pattern.
  factory JValue.fromFloat(double value) {
    final bytes = ByteData(8)..setFloat32(0, value, Endian.little);
    return JValue._(bytes.getInt64(0, Endian.little));
  }

  /// A `jdouble` (`D`), written as its 64-bit IEEE-754 bit pattern.
  factory JValue.fromDouble(double value) {
    final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
    return JValue._(bytes.getInt64(0, Endian.little));
  }

  /// A `jobject` (`L…;` or `[…`), including `jstring` and `jclass`.
  factory JValue.fromPointer(Pointer<Void> value) => JValue._(value.address);

  /// A Java `null` reference.
  static const JValue nullReference = JValue._(0);

  /// Coerces a Dart [value] to the `jvalue` slot for a parameter declared as
  /// [descriptor].
  ///
  /// The descriptor is what makes this unambiguous: a Dart `double` becomes
  /// either a 4-byte `jfloat` or an 8-byte `jdouble` depending on what the
  /// method declares, and an `int` is accepted for any of the five integral
  /// widths. Reference parameters accept an already-converted [Pointer], or
  /// `null`.
  ///
  /// [String] arguments are *not* handled here: they need a `jstring` to be
  /// allocated in the VM, which the caller must do (and then release). The
  /// higher-level call API does that automatically.
  factory JValue.forDescriptor(String descriptor, Object? value) {
    switch (descriptor) {
      case JniType.boolean:
        if (value is bool) return JValue.fromBool(value);
        throw JniError(
          'expected a bool for parameter "$descriptor", '
          'got ${value.runtimeType}',
        );

      case JniType.byte:
      case JniType.char:
      case JniType.short:
      case JniType.int_:
      case JniType.long:
        if (value is int) return JValue.fromInt(value);
        throw JniError(
          'expected an int for parameter "$descriptor", '
          'got ${value.runtimeType}',
        );

      case JniType.float:
        if (value is double) return JValue.fromFloat(value);
        if (value is int) return JValue.fromFloat(value.toDouble());
        throw JniError(
          'expected a double for parameter "$descriptor", '
          'got ${value.runtimeType}',
        );

      case JniType.double_:
        if (value is double) return JValue.fromDouble(value);
        if (value is int) return JValue.fromDouble(value.toDouble());
        throw JniError(
          'expected a double for parameter "$descriptor", '
          'got ${value.runtimeType}',
        );

      case JniType.void_:
        throw JniError('"void" is not a valid parameter type');

      default:
        if (!JniType.isReference(descriptor)) {
          throw JniError('unknown parameter descriptor "$descriptor"');
        }
        if (value == null) return JValue.nullReference;
        if (value is Pointer<Void>) return JValue.fromPointer(value);
        throw JniError(
          'expected a Pointer<Void> or null for reference '
          'parameter "$descriptor", got ${value.runtimeType}',
        );
    }
  }

  @override
  String toString() => 'JValue(0x${bits.toRadixString(16)})';
}

/// Reinterprets the low 32 bits of [bits] as a `jfloat`.
///
/// Needed because `CallFloatMethodA` is bound with a `Float` return type on
/// some paths and read back out of raw storage on others.
double floatFromBits(int bits) => (ByteData(
  8,
)..setInt64(0, bits, Endian.little)).getFloat32(0, Endian.little);

/// Reinterprets [bits] as a `jdouble`.
double doubleFromBits(int bits) => (ByteData(
  8,
)..setInt64(0, bits, Endian.little)).getFloat64(0, Endian.little);
