/// A Java array, at the ergonomic layer.
///
/// [JvmArrays] mirrors JNI: it makes you pick `getIntArray` vs `getLongArray`
/// and hand-manage every element reference. [JavaArray] carries its element
/// descriptor instead, so one type covers all nine element kinds and a call
/// that returns `int[]` or `String[]` comes back as something you can read
/// directly.
///
/// It is a [JavaObject], so it can be passed straight back into another call.
library;

import 'dart:typed_data';

import 'boxing.dart';
import 'errors.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'jvm.dart';
import 'jvm_arrays.dart';
import 'signatures.dart';

/// A Java array of [elementDescriptor] elements.
///
/// ```dart
/// final values = JavaArray.ofInts(jvm, [1, 2, 3]);
/// fixtures.callStatic('sumInts', '([I)I', [values]); // 6
/// values.release();
/// ```
class JavaArray extends JavaObject {
  /// Wraps an existing array reference whose elements are [elementDescriptor].
  JavaArray(super.jvm, super.ref, this.elementDescriptor);

  /// The descriptor of one element: `I`, `Ljava/lang/String;`, `[I`, …
  final String elementDescriptor;

  /// Creates an array holding [values].
  ///
  /// Elements convert exactly as call arguments do — a Dart `String` becomes a
  /// `java.lang.String`, a number is boxed when the element type can hold a
  /// box, and a [JavaObject] or [JavaRef] is stored as-is.
  factory JavaArray.of(
    Jvm jvm,
    String elementDescriptor,
    List<Object?> values,
  ) => JavaArray(
    jvm,
    jvm.newArray(elementDescriptor, [for (final v in values) _unwrap(v)]),
    elementDescriptor,
  );

  /// Creates an array of [length] elements, zero- or `null`-filled.
  factory JavaArray.sized(Jvm jvm, String elementDescriptor, int length) {
    if (JniType.isPrimitive(elementDescriptor)) {
      return JavaArray(
        jvm,
        jvm.newPrimitiveArray(elementDescriptor, length),
        elementDescriptor,
      );
    }
    final component = jvm.elementClass(elementDescriptor);
    try {
      return JavaArray(
        jvm,
        jvm.newObjectArray(length, component),
        elementDescriptor,
      );
    } finally {
      component.release();
    }
  }

  factory JavaArray.ofBooleans(Jvm jvm, List<bool> values) =>
      JavaArray.of(jvm, JniType.boolean, values);

  factory JavaArray.ofBytes(Jvm jvm, List<int> values) =>
      JavaArray.of(jvm, JniType.byte, values);

  /// A `char[]` from UTF-16 code units.
  factory JavaArray.ofChars(Jvm jvm, List<int> values) =>
      JavaArray.of(jvm, JniType.char, values);

  factory JavaArray.ofShorts(Jvm jvm, List<int> values) =>
      JavaArray.of(jvm, JniType.short, values);

  factory JavaArray.ofInts(Jvm jvm, List<int> values) =>
      JavaArray.of(jvm, JniType.int_, values);

  factory JavaArray.ofLongs(Jvm jvm, List<int> values) =>
      JavaArray.of(jvm, JniType.long, values);

  factory JavaArray.ofFloats(Jvm jvm, List<double> values) =>
      JavaArray.of(jvm, JniType.float, values);

  factory JavaArray.ofDoubles(Jvm jvm, List<double> values) =>
      JavaArray.of(jvm, JniType.double_, values);

  /// A `String[]`, preserving `null` elements.
  factory JavaArray.ofStrings(Jvm jvm, List<String?> values) =>
      JavaArray.of(jvm, JniType.string, values);

  /// An `Object[]` of [values], each boxed or converted as reflection expects
  /// its arguments — the array `Method.invoke` takes.
  ///
  /// A `bool`, `int` or `double` becomes its wrapper (an `int` an `Integer`
  /// when it fits in 32 bits, a `Long` otherwise), a `String` a
  /// `java.lang.String`, a [JavaClass] its `java.lang.Class` object, and a
  /// [JavaObject] or [JavaRef] is stored as is. A `Uint8List` becomes a
  /// `byte[]`, and the other typed lists the matching primitive array
  /// (`Int32List` an `int[]`, `Int64List` a `long[]`, `Float64List` a
  /// `double[]`, …). Any other `List` is ambiguous — `Object[]`? `String[]`?
  /// — and throws: build it as a [JavaArray] first.
  factory JavaArray.objectsFrom(Jvm jvm, List<Object?> values) {
    final temporaries = <JavaArray>[];
    try {
      return JavaArray.of(jvm, JniType.object, [
        for (final value in values) _objectElement(jvm, value, temporaries),
      ]);
    } finally {
      for (final temporary in temporaries) {
        temporary.release();
      }
    }
  }

  /// An array of [className] elements, e.g. `java.lang.Object`.
  factory JavaArray.ofObjects(
    Jvm jvm,
    String className,
    List<Object?> values,
  ) => JavaArray.of(jvm, JniType.objectOf(className), values);

  /// This array's own descriptor, e.g. `[I` — one `[` ahead of the element's.
  String get descriptor => JniType.arrayOf(elementDescriptor);

  /// The number of elements.
  int get length => jvm.arrayLength(ref);

  /// `true` when the elements are one of the eight primitives.
  bool get hasPrimitiveElements => JniType.isPrimitive(elementDescriptor);

  /// Copies a `byte[]` into a [Uint8List].
  ///
  /// The right way to get binary data out of Java. `toList()` on a `byte[]`
  /// gives an [Int8List], because Java's `byte` is signed — correct, but every
  /// consumer in Dart (`File.writeAsBytes`, `utf8.decode`, `crypto`) wants
  /// unsigned bytes, and converting afterwards allocates per element.
  ///
  /// ```dart
  /// final digest = md5.callJavaAs<JavaArray>('byte[] digest(byte[])', [input]);
  /// await File('out.bin').writeAsBytes(digest.toBytes());
  /// ```
  ///
  /// Throws [JniError] unless the elements really are `byte`.
  Uint8List toBytes({int start = 0, int? length}) {
    if (elementDescriptor != JniType.byte) {
      throw JniError(
        'toBytes() needs a byte[], got $descriptor — '
        'use toList() for other element types',
      );
    }
    return jvm.getUnsignedByteArray(ref, start: start, length: length);
  }

  /// Copies the array into Dart.
  ///
  /// The list type follows the element type: a primitive array becomes the
  /// matching typed list — `Int32List` for `int[]`, `Float64List` for
  /// `double[]` — so `toList() as Int32List` is safe; a `String[]` becomes
  /// `List<String?>`; a wrapper array such as `Integer[]` is unboxed to
  /// `List<int?>`.
  ///
  /// Any other object array becomes `List<JavaObject?>`, and **each element is
  /// a reference the caller must release** — the cheapest way to do that is to
  /// read them inside a [JvmLocalFrames.localFrame].
  List<Object?> toList({int start = 0, int? length}) {
    final raw = jvm.arrayToList(
      ref,
      elementDescriptor,
      start: start,
      length: length,
    );
    if (raw is! List<JavaRef>) return raw;
    return [for (final element in raw) _wrap(element)];
  }

  /// Reads one element, using the same conversions as [toList].
  Object? operator [](int index) =>
      _wrap(jvm.getArrayElement(ref, elementDescriptor, index));

  /// Writes one element, using the same conversions as [JavaArray.of].
  void operator []=(int index, Object? value) =>
      jvm.setArrayElement(ref, elementDescriptor, index, _unwrap(value));

  /// Wraps a raw element in the friendliest Dart type.
  Object? _wrap(Object? raw) {
    if (raw is! JavaRef) return raw;
    if (raw.isNull) {
      raw.release();
      return null;
    }

    if (elementDescriptor.startsWith('[')) {
      return JavaArray(jvm, raw, elementDescriptor.substring(1));
    }
    final wrapper = JavaWrapper.forDescriptor(elementDescriptor);
    if (wrapper != null) {
      try {
        return jvm.unboxAs(wrapper, raw);
      } finally {
        raw.release();
      }
    }
    return JavaObject(jvm, raw);
  }

  @override
  String toString() =>
      isNull ? 'JavaArray(null)' : 'JavaArray($descriptor[$length])';
}

/// Reduces a [JavaObject] or [JavaClass] to the reference underneath, so the
/// raw array layer never has to know about the ergonomic types.
/// [value] as an element of an `Object[]`, for [JavaArray.objectsFrom]. A
/// primitive array made here goes into [temporaries], for the caller to release
/// once the `Object[]` holds its own reference.
Object? _objectElement(Jvm jvm, Object? value, List<JavaArray> temporaries) {
  final String? descriptor = switch (value) {
    Uint8List() || Int8List() => JniType.byte,
    Int16List() => JniType.short,
    Uint16List() => JniType.char,
    Int32List() => JniType.int_,
    Int64List() => JniType.long,
    Float32List() => JniType.float,
    Float64List() => JniType.double_,
    _ => null,
  };
  if (descriptor != null) {
    final array = JavaArray.of(jvm, descriptor, value as List<Object?>);
    temporaries.add(array);
    return array.ref;
  }
  if (value is List) {
    throw JniError(
      'cannot put a ${value.runtimeType} in an Object[]: the element type is '
      'ambiguous; build it with JavaArray.ofStrings/ofObjects/… first',
    );
  }
  return _unwrap(value);
}

Object? _unwrap(Object? value) {
  if (value is JavaObject) return value.ref;
  if (value is JavaClass) return value.ref;
  return value;
}
