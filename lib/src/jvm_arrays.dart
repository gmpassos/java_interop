/// Java arrays: creation, length, and bulk element transfer.
///
/// Primitive arrays move through `Get`/`Set<Type>ArrayRegion`, which copy into
/// or out of a caller-owned buffer. The `GetArrayElements` family is not bound:
/// it may hand back a *direct pointer* into the Java heap and pin it, which is
/// easy to leak and blocks the GC for as long as it is held. Region copies are
/// simpler to reason about and fast enough for anything crossing this boundary.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';
import 'signatures.dart';

/// Array creation and access.
extension JvmArrays on Jvm {
  /// The length of any Java array.
  int arrayLength(JavaRef array) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, JniFn.getArrayLength)
        .cast<NativeFunction<GetArrayLengthC>>()
        .asFunction<GetArrayLengthDart>()(env, array.pointer);
    checkException();
    return result;
  }

  // --- Object arrays -------------------------------------------------------

  /// Creates a `elementClass[length]`, every slot initialised to
  /// [initialElement] (Java `null` when omitted).
  JavaRef newObjectArray(
    int length,
    JavaRef elementClass, [
    JavaRef? initialElement,
  ]) {
    final env = this.env;
    final array =
        Jvm.fnSlotOf(env, JniFn.newObjectArray)
            .cast<NativeFunction<NewObjectArrayC>>()
            .asFunction<NewObjectArrayDart>()(
          env,
          length,
          elementClass.pointer,
          initialElement == null ? nullptr : initialElement.pointer,
        );
    checkException();
    return JavaRef(this, array, JavaRefKind.local);
  }

  /// Reads one element of an object array.
  JavaRef getObjectArrayElement(JavaRef array, int index) {
    final env = this.env;
    final element = Jvm.fnSlotOf(env, JniFn.getObjectArrayElement)
        .cast<NativeFunction<GetObjectArrayElementC>>()
        .asFunction<GetObjectArrayElementDart>()(env, array.pointer, index);
    // Out-of-range raises ArrayIndexOutOfBoundsException on the Java side.
    checkException();
    return JavaRef(this, element, JavaRefKind.local);
  }

  /// Writes one element of an object array. [value] may be `null`.
  void setObjectArrayElement(JavaRef array, int index, JavaRef? value) {
    final env = this.env;
    Jvm.fnSlotOf(env, JniFn.setObjectArrayElement)
        .cast<NativeFunction<SetObjectArrayElementC>>()
        .asFunction<SetObjectArrayElementDart>()(
      env,
      array.pointer,
      index,
      value == null ? nullptr : value.pointer,
    );
    checkException();
  }

  // --- Primitive array creation --------------------------------------------

  JavaRef newBooleanArray(int length) =>
      _newPrimitiveArray(JniFn.newBooleanArray, length);

  JavaRef newByteArray(int length) =>
      _newPrimitiveArray(JniFn.newByteArray, length);

  JavaRef newCharArray(int length) =>
      _newPrimitiveArray(JniFn.newCharArray, length);

  JavaRef newShortArray(int length) =>
      _newPrimitiveArray(JniFn.newShortArray, length);

  JavaRef newIntArray(int length) =>
      _newPrimitiveArray(JniFn.newIntArray, length);

  JavaRef newLongArray(int length) =>
      _newPrimitiveArray(JniFn.newLongArray, length);

  JavaRef newFloatArray(int length) =>
      _newPrimitiveArray(JniFn.newFloatArray, length);

  JavaRef newDoubleArray(int length) =>
      _newPrimitiveArray(JniFn.newDoubleArray, length);

  /// Creates a primitive array whose element type is given by [descriptor]
  /// (one of `Z B C S I J F D`).
  JavaRef newPrimitiveArray(String descriptor, int length) {
    switch (descriptor) {
      case JniType.boolean:
        return newBooleanArray(length);
      case JniType.byte:
        return newByteArray(length);
      case JniType.char:
        return newCharArray(length);
      case JniType.short:
        return newShortArray(length);
      case JniType.int_:
        return newIntArray(length);
      case JniType.long:
        return newLongArray(length);
      case JniType.float:
        return newFloatArray(length);
      case JniType.double_:
        return newDoubleArray(length);
      default:
        throw JniError('not a primitive array element type: "$descriptor"');
    }
  }

  JavaRef _newPrimitiveArray(int slot, int length) {
    if (length < 0) throw JniError('negative array length: $length');
    final env = this.env;
    final array = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<NewPrimitiveArrayC>>()
        .asFunction<NewPrimitiveArrayDart>()(env, length);
    checkException();
    return JavaRef(this, array, JavaRefKind.local);
  }

  // --- Primitive array reads -----------------------------------------------

  /// Reads a `boolean[]` as a list of Dart `bool`s.
  List<bool> getBooleanArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return const [];
    return using((arena) {
      final buffer = arena<Uint8>(count);
      _region(JniFn.getBooleanArrayRegion, array, start, count, buffer.cast());
      return [for (var i = 0; i < count; i++) buffer[i] != 0];
    });
  }

  /// Reads a `byte[]`. Java bytes are signed, so this is an [Int8List].
  Int8List getByteArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Int8List(0);
    return using((arena) {
      final buffer = arena<Int8>(count);
      _region(JniFn.getByteArrayRegion, array, start, count, buffer.cast());
      return Int8List.fromList(buffer.asTypedList(count));
    });
  }

  /// Reads a `char[]` as UTF-16 code units.
  Uint16List getCharArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Uint16List(0);
    return using((arena) {
      final buffer = arena<Uint16>(count);
      _region(JniFn.getCharArrayRegion, array, start, count, buffer.cast());
      return Uint16List.fromList(buffer.asTypedList(count));
    });
  }

  Int16List getShortArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Int16List(0);
    return using((arena) {
      final buffer = arena<Int16>(count);
      _region(JniFn.getShortArrayRegion, array, start, count, buffer.cast());
      return Int16List.fromList(buffer.asTypedList(count));
    });
  }

  Int32List getIntArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Int32List(0);
    return using((arena) {
      final buffer = arena<Int32>(count);
      _region(JniFn.getIntArrayRegion, array, start, count, buffer.cast());
      return Int32List.fromList(buffer.asTypedList(count));
    });
  }

  Int64List getLongArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Int64List(0);
    return using((arena) {
      final buffer = arena<Int64>(count);
      _region(JniFn.getLongArrayRegion, array, start, count, buffer.cast());
      return Int64List.fromList(buffer.asTypedList(count));
    });
  }

  Float32List getFloatArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Float32List(0);
    return using((arena) {
      final buffer = arena<Float>(count);
      _region(JniFn.getFloatArrayRegion, array, start, count, buffer.cast());
      return Float32List.fromList(buffer.asTypedList(count));
    });
  }

  Float64List getDoubleArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Float64List(0);
    return using((arena) {
      final buffer = arena<Double>(count);
      _region(JniFn.getDoubleArrayRegion, array, start, count, buffer.cast());
      return Float64List.fromList(buffer.asTypedList(count));
    });
  }

  // --- Primitive array writes ----------------------------------------------

  void setBooleanArray(JavaRef array, List<bool> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Uint8>(values.length);
      for (var i = 0; i < values.length; i++) {
        buffer[i] = values[i] ? 1 : 0;
      }
      _region(
        JniFn.setBooleanArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setByteArray(JavaRef array, List<int> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Int8>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setByteArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setCharArray(JavaRef array, List<int> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Uint16>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setCharArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setShortArray(JavaRef array, List<int> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Int16>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setShortArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setIntArray(JavaRef array, List<int> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Int32>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setIntArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setLongArray(JavaRef array, List<int> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Int64>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setLongArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setFloatArray(JavaRef array, List<double> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Float>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setFloatArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  void setDoubleArray(JavaRef array, List<double> values, {int start = 0}) {
    if (values.isEmpty) return;
    using((arena) {
      final buffer = arena<Double>(values.length);
      buffer.asTypedList(values.length).setAll(0, values);
      _region(
        JniFn.setDoubleArrayRegion,
        array,
        start,
        values.length,
        buffer.cast(),
      );
    });
  }

  // --- Internals -----------------------------------------------------------

  int _regionLength(JavaRef array, int start, int? length) {
    if (start < 0) throw JniError('negative array start: $start');
    final total = arrayLength(array);
    final count = length ?? (total - start);
    if (count < 0 || start + count > total) {
      throw JniError(
        'array region [$start, ${start + count}) is outside '
        'an array of length $total',
      );
    }
    return count;
  }

  void _region(
    int slot,
    JavaRef array,
    int start,
    int count,
    Pointer<Void> buffer,
  ) {
    final env = this.env;
    Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<ArrayRegionC>>().asFunction<ArrayRegionDart>()(
      env,
      array.pointer,
      start,
      count,
      buffer,
    );
    checkException();
  }
}
