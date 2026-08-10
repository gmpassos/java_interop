/// Boxing Dart values into the `java.lang` primitive wrappers, and back.
///
/// Java's autoboxing is a *compiler* feature: `map.put("a", 1)` is compiled to
/// `map.put("a", Integer.valueOf(1))`. JNI has no such step, so a method
/// declared `(Ljava/lang/Object;)V` cannot be handed a Dart `int` — it needs an
/// `Integer` built first. This library builds it, and unboxes on the way back.
///
/// The wrapper classes are resolved once per [Jvm] and held as *global*
/// references that are never released. They are `java.lang` types, loaded by the
/// bootstrap class loader for the life of the VM, so pinning them costs nothing
/// and saves a `FindClass` plus two `GetMethodID`s per boxed value.
library;

import 'dart:ffi';

import 'errors.dart';
import 'java_ref.dart';
import 'jvalue.dart';
import 'jvm.dart';
import 'jvm_calls.dart';
import 'jvm_classes.dart';
import 'signatures.dart';

/// One of the eight `java.lang` primitive wrapper classes.
class JavaWrapper {
  const JavaWrapper._(
    this.descriptor,
    this.className,
    this.primitive,
    this.unboxMethod,
  );

  /// The wrapper's own type descriptor, e.g. `Ljava/lang/Integer;`.
  final String descriptor;

  /// The dotted class name, e.g. `java.lang.Integer`.
  final String className;

  /// The primitive descriptor it wraps, e.g. `I`.
  final String primitive;

  /// The accessor that unwraps it, e.g. `intValue`.
  final String unboxMethod;

  static const boolean = JavaWrapper._(
    'Ljava/lang/Boolean;',
    'java.lang.Boolean',
    JniType.boolean,
    'booleanValue',
  );
  static const byte = JavaWrapper._(
    'Ljava/lang/Byte;',
    'java.lang.Byte',
    JniType.byte,
    'byteValue',
  );
  static const char = JavaWrapper._(
    'Ljava/lang/Character;',
    'java.lang.Character',
    JniType.char,
    'charValue',
  );
  static const short = JavaWrapper._(
    'Ljava/lang/Short;',
    'java.lang.Short',
    JniType.short,
    'shortValue',
  );
  static const int_ = JavaWrapper._(
    'Ljava/lang/Integer;',
    'java.lang.Integer',
    JniType.int_,
    'intValue',
  );
  static const long = JavaWrapper._(
    'Ljava/lang/Long;',
    'java.lang.Long',
    JniType.long,
    'longValue',
  );
  static const float = JavaWrapper._(
    'Ljava/lang/Float;',
    'java.lang.Float',
    JniType.float,
    'floatValue',
  );
  static const double_ = JavaWrapper._(
    'Ljava/lang/Double;',
    'java.lang.Double',
    JniType.double_,
    'doubleValue',
  );

  /// All eight, in JNI descriptor order.
  static const values = [
    boolean,
    byte,
    char,
    short,
    int_,
    long,
    float,
    double_,
  ];

  /// Reference descriptors that can hold *any* boxed primitive, and so leave
  /// the wrapper to be inferred from the Dart value.
  ///
  /// These are what generics erase to, which is why `List<Integer>.add` has the
  /// descriptor `(Ljava/lang/Object;)Z` and not `(Ljava/lang/Integer;)Z`.
  static const erased = {
    JniType.object,
    'Ljava/lang/Number;',
    'Ljava/lang/Comparable;',
    'Ljava/io/Serializable;',
  };

  /// `Integer.valueOf`'s signature, e.g. `(I)Ljava/lang/Integer;`.
  String get valueOfSignature => '($primitive)$descriptor';

  /// `intValue`'s signature, e.g. `()I`.
  String get unboxSignature => '()$primitive';

  /// The wrapper named by [descriptor], or `null` when it names something else.
  static JavaWrapper? forDescriptor(String descriptor) {
    switch (descriptor) {
      case 'Ljava/lang/Boolean;':
        return boolean;
      case 'Ljava/lang/Byte;':
        return byte;
      case 'Ljava/lang/Character;':
        return char;
      case 'Ljava/lang/Short;':
        return short;
      case 'Ljava/lang/Integer;':
        return int_;
      case 'Ljava/lang/Long;':
        return long;
      case 'Ljava/lang/Float;':
        return float;
      case 'Ljava/lang/Double;':
        return double_;
      default:
        return null;
    }
  }

  /// The wrapper for a primitive [descriptor] such as `I`, or `null`.
  static JavaWrapper? forPrimitive(String descriptor) {
    for (final wrapper in values) {
      if (wrapper.primitive == descriptor) return wrapper;
    }
    return null;
  }

  @override
  String toString() => 'JavaWrapper($className)';
}

/// Boxing and unboxing primitives.
extension JvmBoxing on Jvm {
  /// `true` when a Dart `bool`, `int` or `double` can be boxed into a reference
  /// declared as [descriptor].
  ///
  /// True for the eight wrappers themselves and for the erased types generics
  /// compile down to; false for `Ljava/lang/String;`, `[I`, or any other class,
  /// where a bare number is a mistake rather than something to convert.
  bool canBox(String descriptor) =>
      JavaWrapper.forDescriptor(descriptor) != null ||
      JavaWrapper.erased.contains(descriptor);

  /// Boxes [value] for a parameter or field declared as [descriptor].
  ///
  /// When [descriptor] names a wrapper the choice is exact. When it is one of
  /// [JavaWrapper.erased] the wrapper is *inferred*, which is the one place
  /// this binding has to guess what javac would have known statically:
  ///
  /// - `bool` becomes a `Boolean`
  /// - `double` becomes a `Double`
  /// - `int` becomes an `Integer` when it fits in 32 bits, otherwise a `Long`
  ///
  /// The int/long split matters for `equals` — `Integer.valueOf(1)` is not
  /// equal to `Long.valueOf(1)` — so pass an explicit [boxLong] (or any
  /// [JavaObject]) when the Java side stores a specific width.
  ///
  /// The returned reference is local; release it when done.
  JavaRef box(String descriptor, Object value) {
    final exact = JavaWrapper.forDescriptor(descriptor);
    if (exact != null) return boxAs(exact, value);

    if (!JavaWrapper.erased.contains(descriptor)) {
      throw JniError(
        'cannot box ${value.runtimeType} as "$descriptor": '
        'it is not a primitive wrapper type',
      );
    }
    return boxAs(_inferWrapper(descriptor, value), value);
  }

  JavaWrapper _inferWrapper(String descriptor, Object value) {
    if (value is bool) {
      if (descriptor == 'Ljava/lang/Number;') {
        throw JniError('cannot box a bool as "$descriptor"');
      }
      return JavaWrapper.boolean;
    }
    if (value is double) return JavaWrapper.double_;
    if (value is int) {
      const minInt32 = -2147483648;
      const maxInt32 = 2147483647;
      return value >= minInt32 && value <= maxInt32
          ? JavaWrapper.int_
          : JavaWrapper.long;
    }
    throw JniError(
      'cannot box ${value.runtimeType} as "$descriptor": '
      'expected a bool, int or double',
    );
  }

  /// Boxes [value] with a specific [wrapper], bypassing inference.
  JavaRef boxAs(JavaWrapper wrapper, Object value) {
    final entry = _wrapperEntry(wrapper);
    return callStaticObjectMethod(entry.clazz, entry.valueOf, [
      JValue.forDescriptor(wrapper.primitive, value),
    ]);
  }

  JavaRef boxBoolean(bool value) => boxAs(JavaWrapper.boolean, value);

  JavaRef boxByte(int value) => boxAs(JavaWrapper.byte, value);

  /// Boxes a UTF-16 code unit as a `java.lang.Character`.
  JavaRef boxChar(int value) => boxAs(JavaWrapper.char, value);

  JavaRef boxShort(int value) => boxAs(JavaWrapper.short, value);

  JavaRef boxInt(int value) => boxAs(JavaWrapper.int_, value);

  JavaRef boxLong(int value) => boxAs(JavaWrapper.long, value);

  JavaRef boxFloat(double value) => boxAs(JavaWrapper.float, value);

  JavaRef boxDouble(double value) => boxAs(JavaWrapper.double_, value);

  /// Unboxes a reference declared as [descriptor], which must name a wrapper.
  ///
  /// Returns `null` for a Java `null`, so an `Integer` field that is unset
  /// comes back as `null` rather than `0`.
  Object? unbox(String descriptor, JavaRef value) {
    final wrapper = JavaWrapper.forDescriptor(descriptor);
    if (wrapper == null) {
      throw JniError('not a primitive wrapper type: "$descriptor"');
    }
    return unboxAs(wrapper, value);
  }

  /// Unboxes [value] as a specific [wrapper].
  Object? unboxAs(JavaWrapper wrapper, JavaRef value) {
    if (value.isNull) return null;
    final entry = _wrapperEntry(wrapper);
    switch (wrapper.primitive) {
      case JniType.boolean:
        return callBooleanMethod(value, entry.unbox);
      case JniType.byte:
        return callByteMethod(value, entry.unbox);
      case JniType.char:
        return callCharMethod(value, entry.unbox);
      case JniType.short:
        return callShortMethod(value, entry.unbox);
      case JniType.int_:
        return callIntMethod(value, entry.unbox);
      case JniType.long:
        return callLongMethod(value, entry.unbox);
      case JniType.float:
        return callFloatMethod(value, entry.unbox);
      default:
        return callDoubleMethod(value, entry.unbox);
    }
  }

  /// The wrapper class [value] is an instance of, or `null` when it is not a
  /// boxed primitive.
  ///
  /// This is the *runtime* answer, for the common case where the declared type
  /// is `Object` and the actual type is only knowable by asking.
  JavaWrapper? wrapperOf(JavaRef value) {
    if (value.isNull) return null;
    for (final wrapper in JavaWrapper.values) {
      if (isInstanceOf(value, _wrapperEntry(wrapper).clazz)) return wrapper;
    }
    return null;
  }

  /// `true` when [value] is a `java.lang.String`.
  bool isJavaString(JavaRef value) =>
      !value.isNull && isInstanceOf(value, javaLangString);

  /// The cached `java.lang.String` class, as a global reference owned by this
  /// library. Do not release it.
  JavaRef get javaLangString {
    final table = _wellKnown[this] ??= _WellKnown();
    return table.stringClass ??= _globalClass('java.lang.String');
  }

  _WrapperEntry _wrapperEntry(JavaWrapper wrapper) {
    final table = _wellKnown[this] ??= _WellKnown();
    return table.wrappers.putIfAbsent(wrapper.descriptor, () {
      final clazz = _globalClass(wrapper.className);
      return _WrapperEntry(
        clazz,
        staticMethodId(clazz, 'valueOf', wrapper.valueOfSignature),
        methodId(clazz, wrapper.unboxMethod, wrapper.unboxSignature),
      );
    });
  }

  JavaRef _globalClass(String className) {
    final local = findClass(className);
    try {
      return local.toGlobal();
    } finally {
      local.release();
    }
  }
}

/// Per-[Jvm] cache of the classes and member ids used for boxing.
///
/// Keyed by the [Jvm] instance rather than held in a static so that an isolate
/// which attached to someone else's VM builds its own — a `jmethodID` is fine
/// to share, but the [JavaRef] wrapper carries an isolate's [Jvm].
final Expando<_WellKnown> _wellKnown = Expando('java_interop well-known types');

class _WellKnown {
  final Map<String, _WrapperEntry> wrappers = {};
  JavaRef? stringClass;
}

class _WrapperEntry {
  _WrapperEntry(this.clazz, this.valueOf, this.unbox);

  /// A global reference, deliberately never released.
  final JavaRef clazz;
  final Pointer<Void> valueOf;
  final Pointer<Void> unbox;
}
