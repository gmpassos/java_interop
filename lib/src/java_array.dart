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

import 'boxing.dart';
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
Object? _unwrap(Object? value) {
  if (value is JavaObject) return value.ref;
  if (value is JavaClass) return value.ref;
  return value;
}
