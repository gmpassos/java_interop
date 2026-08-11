/// Java arrays: creation, length, and bulk element transfer.
///
/// Primitive arrays move through `Get`/`Set<Type>ArrayRegion`, which copy into
/// or out of a caller-owned buffer. The `GetArrayElements` family is not bound:
/// it may hand back a *direct pointer* into the Java heap and pin it, which is
/// easy to leak and blocks the GC for as long as it is held. Region copies are
/// simpler to reason about and fast enough for anything crossing this boundary.
///
/// The `…ArrayRegion` calls at the bottom are the JNI surface; on top of them
/// sit descriptor-driven helpers ([JvmArrays.newArray], [JvmArrays.arrayToList],
/// [JvmArrays.getArrayElement], [JvmArrays.setArrayElement]) that take the
/// element type as a string, which is what `JavaArray` is built from.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'boxing.dart';
import 'errors.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'jvm_classes.dart';
import 'jvm_strings.dart';
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
  ///
  /// For binary data — a file, a hash, a PDF — [getUnsignedByteArray] is almost
  /// always what you want instead.
  Int8List getByteArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Int8List(0);
    return using((arena) {
      final buffer = arena<Int8>(count);
      _region(JniFn.getByteArrayRegion, array, start, count, buffer.cast());
      return Int8List.fromList(buffer.asTypedList(count));
    });
  }

  /// Reads a `byte[]` as unsigned bytes.
  ///
  /// The same eight bits as [getByteArray], read straight into a [Uint8List] —
  /// which is what the rest of Dart wants for binary data: `dart:io` writes it,
  /// `dart:convert` decodes it, `crypto` digests it.
  ///
  /// Prefer this over converting afterwards. `getByteArray(...).map((b) => b &
  /// 0xff)` is the obvious move and it both allocates per element and produces a
  /// plain `List<int>` rather than a typed list; on a few hundred kilobytes that
  /// is a measurable waste. Reading the region into the right buffer costs the
  /// single copy JNI requires either way.
  Uint8List getUnsignedByteArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    if (count == 0) return Uint8List(0);
    return using((arena) {
      final buffer = arena<Uint8>(count);
      _region(JniFn.getByteArrayRegion, array, start, count, buffer.cast());
      return Uint8List.fromList(buffer.asTypedList(count));
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

  // --- Descriptor-driven access --------------------------------------------

  /// The `jclass` for an array's element type.
  ///
  /// `Ljava/lang/String;` resolves `java.lang.String`; a nested array
  /// descriptor such as `[I` is handed to `FindClass` as-is, which is exactly
  /// how JNI names array classes.
  ///
  /// The returned reference is local; release it.
  JavaRef elementClass(String elementDescriptor) {
    if (elementDescriptor.startsWith('[')) return findClass(elementDescriptor);
    if (elementDescriptor.startsWith('L') && elementDescriptor.endsWith(';')) {
      return findClass(
        elementDescriptor.substring(1, elementDescriptor.length - 1),
      );
    }
    throw JniError('not a reference element descriptor: "$elementDescriptor"');
  }

  /// Creates a Java array of [elementDescriptor] elements holding [values].
  ///
  /// Elements are converted the way arguments are: a Dart `String` becomes a
  /// `java.lang.String`, a `bool`/`int`/`double` is boxed when the element type
  /// can hold a box, and a [JavaRef] is stored as-is. Every temporary this
  /// creates is released before returning — the array itself holds the
  /// references that matter.
  ///
  /// The returned reference is local; release it.
  JavaRef newArray(String elementDescriptor, List<Object?> values) {
    if (JniType.isPrimitive(elementDescriptor)) {
      final array = newPrimitiveArray(elementDescriptor, values.length);
      if (values.isEmpty) return array;
      try {
        _fillPrimitiveArray(array, elementDescriptor, values);
      } on Object {
        array.release();
        rethrow;
      }
      return array;
    }

    final component = elementClass(elementDescriptor);
    try {
      final array = newObjectArray(values.length, component);
      try {
        for (var i = 0; i < values.length; i++) {
          // Slots start out null, so a null element needs no work.
          if (values[i] == null) continue;
          setArrayElement(array, elementDescriptor, i, values[i]);
        }
      } on Object {
        array.release();
        rethrow;
      }
      return array;
    } finally {
      component.release();
    }
  }

  /// Reads a whole array into Dart, choosing the natural list type for
  /// [elementDescriptor].
  ///
  /// Primitive arrays come back as the matching typed list ([Int32List],
  /// [Float64List], …), a `String[]` as `List<String?>`, and any other object
  /// array as `List<JavaRef>` of fresh local references **the caller must
  /// release**.
  List<Object?> arrayToList(
    JavaRef array,
    String elementDescriptor, {
    int start = 0,
    int? length,
  }) {
    switch (elementDescriptor) {
      case JniType.boolean:
        return getBooleanArray(array, start: start, length: length);
      case JniType.byte:
        return getByteArray(array, start: start, length: length);
      case JniType.char:
        return getCharArray(array, start: start, length: length);
      case JniType.short:
        return getShortArray(array, start: start, length: length);
      case JniType.int_:
        return getIntArray(array, start: start, length: length);
      case JniType.long:
        return getLongArray(array, start: start, length: length);
      case JniType.float:
        return getFloatArray(array, start: start, length: length);
      case JniType.double_:
        return getDoubleArray(array, start: start, length: length);
      case JniType.string:
        return getStringArray(array, start: start, length: length);
      default:
        if (!JniType.isReference(elementDescriptor)) {
          throw JniError('unknown element descriptor "$elementDescriptor"');
        }
        return getObjectArray(array, start: start, length: length);
    }
  }

  /// A `String[]` as Dart strings, preserving `null` elements.
  List<String?> getStringArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    return [
      for (var i = 0; i < count; i++)
        _takeString(getObjectArrayElement(array, start + i)),
    ];
  }

  /// An object array's elements as fresh local references.
  ///
  /// Every element is a reference the caller owns and must [JavaRef.release].
  List<JavaRef> getObjectArray(JavaRef array, {int start = 0, int? length}) {
    final count = _regionLength(array, start, length);
    return [
      for (var i = 0; i < count; i++) getObjectArrayElement(array, start + i),
    ];
  }

  /// Reads one element, as the natural Dart type for [elementDescriptor].
  ///
  /// A reference element other than `java.lang.String` comes back as a
  /// [JavaRef] the caller must release.
  Object? getArrayElement(JavaRef array, String elementDescriptor, int index) {
    if (JniType.isPrimitive(elementDescriptor)) {
      return arrayToList(
        array,
        elementDescriptor,
        start: index,
        length: 1,
      ).first;
    }
    if (!JniType.isReference(elementDescriptor)) {
      throw JniError('unknown element descriptor "$elementDescriptor"');
    }

    final element = getObjectArrayElement(array, index);
    if (elementDescriptor == JniType.string) return _takeString(element);
    return element;
  }

  /// Writes one element, converting [value] for [elementDescriptor].
  ///
  /// Accepts the same shapes as [newArray]; any temporary it allocates is
  /// released before returning.
  void setArrayElement(
    JavaRef array,
    String elementDescriptor,
    int index,
    Object? value,
  ) {
    if (JniType.isPrimitive(elementDescriptor)) {
      if (value == null) {
        throw JniError('cannot store null in a "$elementDescriptor" array');
      }
      _fillPrimitiveArray(array, elementDescriptor, [value], start: index);
      return;
    }
    if (!JniType.isReference(elementDescriptor)) {
      throw JniError('unknown element descriptor "$elementDescriptor"');
    }

    if (value == null) {
      setObjectArrayElement(array, index, null);
      return;
    }
    if (value is JavaRef) {
      setObjectArrayElement(array, index, value);
      return;
    }

    // Needs a temporary: a jstring, a nested array or a box, which the array
    // takes its own reference to as soon as it is stored.
    final JavaRef temporary;
    if (value is String) {
      if (elementDescriptor.startsWith('[')) {
        throw JniError('cannot store a String in a "$elementDescriptor" array');
      }
      temporary = newString(value);
    } else if (value is List) {
      if (!elementDescriptor.startsWith('[')) {
        throw JniError(
          'cannot store a List in a "$elementDescriptor" array; '
          'the element type is not itself an array',
        );
      }
      temporary = newArray(elementDescriptor.substring(1), value);
    } else if (value is bool || value is int || value is double) {
      temporary = box(elementDescriptor, value);
    } else {
      throw JniError(
        'cannot store ${value.runtimeType} in a "$elementDescriptor" array; '
        'use a String, List, JavaRef, bool, int, double or null',
      );
    }

    try {
      setObjectArrayElement(array, index, temporary);
    } finally {
      temporary.release();
    }
  }

  // --- Internals -----------------------------------------------------------

  /// Reads [string] into Dart and releases it, for the bulk String paths.
  String? _takeString(JavaRef string) {
    try {
      return stringFrom(string);
    } finally {
      string.release();
    }
  }

  void _fillPrimitiveArray(
    JavaRef array,
    String elementDescriptor,
    List<Object?> values, {
    int start = 0,
  }) {
    switch (elementDescriptor) {
      case JniType.boolean:
        setBooleanArray(
          array,
          _expectAll<bool>(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.byte:
        setByteArray(
          array,
          _expectAll<int>(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.char:
        setCharArray(
          array,
          _expectAll<int>(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.short:
        setShortArray(
          array,
          _expectAll<int>(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.int_:
        setIntArray(
          array,
          _expectAll<int>(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.long:
        setLongArray(
          array,
          _expectAll<int>(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.float:
        setFloatArray(
          array,
          _expectDoubles(elementDescriptor, values),
          start: start,
        );
        return;
      case JniType.double_:
        setDoubleArray(
          array,
          _expectDoubles(elementDescriptor, values),
          start: start,
        );
        return;
      default:
        throw JniError(
          'not a primitive array element type: "$elementDescriptor"',
        );
    }
  }

  static List<T> _expectAll<T>(String descriptor, List<Object?> values) {
    final result = <T>[];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value is! T) {
        throw JniError(
          'element $i of a "$descriptor" array: expected $T, '
          'got ${value.runtimeType}',
        );
      }
      result.add(value);
    }
    return result;
  }

  /// Like [_expectAll], but widening an `int` to a `double` the way `F` and `D`
  /// parameters do elsewhere.
  static List<double> _expectDoubles(String descriptor, List<Object?> values) {
    final result = <double>[];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value is! num) {
        throw JniError(
          'element $i of a "$descriptor" array: expected a double, '
          'got ${value.runtimeType}',
        );
      }
      result.add(value.toDouble());
    }
    return result;
  }

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
