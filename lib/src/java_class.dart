/// The ergonomic layer: [JavaClass] and [JavaObject].
///
/// The raw extensions on [Jvm] mirror JNI one-to-one, which means the caller
/// has to pick `callIntMethod` vs `callObjectMethod` to match the descriptor —
/// and picking wrong is undefined behaviour, not an error. This layer reads the
/// signature instead and dispatches for you, converts Dart arguments (including
/// `String`, which needs a `jstring` allocated and freed), and releases the
/// temporaries it creates.
library;

import 'dart:ffi';

import 'errors.dart';
import 'java_ref.dart';
import 'jvalue.dart';
import 'jvm.dart';
import 'jvm_calls.dart';
import 'jvm_classes.dart';
import 'jvm_fields.dart';
import 'jvm_strings.dart';
import 'signatures.dart';

/// A resolved Java class.
///
/// Holds a reference to the `jclass`; [release] it when done, or build it as a
/// [global] to keep across frames and threads.
class JavaClass {
  JavaClass(this.jvm, this.ref, this.name);

  final Jvm jvm;

  /// The underlying `jclass` reference.
  final JavaRef ref;

  /// The dotted class name this was looked up with.
  final String name;

  /// Looks up [name] (dotted or slashed) and wraps it.
  factory JavaClass.forName(Jvm jvm, String name, {bool global = false}) {
    final local = jvm.findClass(name);
    if (!global) {
      return JavaClass(jvm, local, JniType.classNameToDotted(name));
    }
    // A global reference survives the frame and the thread, at the cost of an
    // explicit release.
    final globalRef = local.toGlobal();
    local.release();
    return JavaClass(jvm, globalRef, JniType.classNameToDotted(name));
  }

  /// Constructs an instance.
  ///
  /// [signature] is the constructor descriptor, e.g. `(Ljava/lang/String;I)V`.
  JavaObject newInstance([
    String signature = '()V',
    List<Object?> args = const [],
  ]) {
    final parsed = JniSignature.parse(signature);
    _checkArity(parsed, args, '<init>');

    final constructor = jvm.methodId(ref, '<init>', signature);

    return _withConvertedArguments(jvm, parsed, args, (values) {
      final object = jvm.newObject(ref, constructor, values);
      return JavaObject(jvm, object, this);
    });
  }

  /// Calls a static method and returns the result as the natural Dart type:
  /// `null` for `void`, `bool`, `int`, `double`, a [JavaObject] for a
  /// reference, or a [String] when the method returns `java.lang.String`.
  Object? callStatic(
    String methodName,
    String signature, [
    List<Object?> args = const [],
  ]) {
    final parsed = JniSignature.parse(signature);
    _checkArity(parsed, args, methodName);

    final method = jvm.staticMethodId(ref, methodName, signature);

    return _withConvertedArguments(jvm, parsed, args, (values) {
      final result = jvm.callByReturnType(
        parsed.returnType,
        ref,
        method,
        values,
        static: true,
      );
      return _boxResult(jvm, parsed.returnType, result);
    });
  }

  /// [callStatic], typed. Throws a [JniError] if the result is not a `T`.
  T callStaticAs<T>(
    String methodName,
    String signature, [
    List<Object?> args = const [],
  ]) => _cast<T>(callStatic(methodName, signature, args), methodName);

  /// Reads a static field. [descriptor] is a *type* descriptor, e.g. `I`.
  Object? getStaticField(String fieldName, String descriptor) {
    final field = jvm.staticFieldId(ref, fieldName, descriptor);
    final value = jvm.getFieldByType(descriptor, ref, field, static: true);
    return _boxResult(jvm, descriptor, value);
  }

  /// Writes a static field.
  ///
  /// A Dart [String] is converted to a `java.lang.String` and released after
  /// the write.
  void setStaticField(String fieldName, String descriptor, Object? value) {
    final field = jvm.staticFieldId(ref, fieldName, descriptor);
    _withConvertedField(jvm, descriptor, value, (converted) {
      jvm.setFieldByType(descriptor, ref, field, converted, static: true);
    });
  }

  /// The superclass, or `null` for `Object`, primitives and interfaces.
  JavaClass? get superclass {
    final superRef = jvm.getSuperclass(ref);
    if (superRef.isNull) {
      superRef.release();
      return null;
    }
    // `superRef` is already a jclass, so its name comes from calling getName()
    // on it directly — asking for its *runtime* class would just say
    // "java.lang.Class".
    return JavaClass(jvm, superRef, _nameOfClass(jvm, superRef));
  }

  /// Whether an instance of [other] can be assigned to this class.
  bool isAssignableFrom(JavaClass other) =>
      jvm.isAssignableFrom(other.ref, ref);

  /// Releases the class reference.
  void release() => ref.release();

  @override
  String toString() => 'JavaClass($name)';
}

/// An instance of a Java class.
class JavaObject {
  JavaObject(this.jvm, this.ref, [this._type]);

  final Jvm jvm;

  /// The underlying `jobject` reference.
  final JavaRef ref;

  JavaClass? _type;

  /// `true` when this wraps Java `null`.
  bool get isNull => ref.isNull;

  /// The runtime class, resolved lazily via `Object.getClass()`.
  JavaClass get type =>
      _type ??= JavaClass(jvm, jvm.getObjectClass(ref), _classNameOf(jvm, ref));

  /// Calls an instance method. See [JavaClass.callStatic] for the result types.
  Object? call(
    String methodName,
    String signature, [
    List<Object?> args = const [],
  ]) {
    final parsed = JniSignature.parse(signature);
    _checkArity(parsed, args, methodName);

    // The method is resolved against the *declared* class when known, so a
    // package-private or overridden method resolves the same way javac would.
    final lookupClass = _type?.ref ?? jvm.getObjectClass(ref);
    final ownsLookupClass = _type == null;

    try {
      final method = jvm.methodId(lookupClass, methodName, signature);

      return _withConvertedArguments(jvm, parsed, args, (values) {
        final result = jvm.callByReturnType(
          parsed.returnType,
          ref,
          method,
          values,
          static: false,
        );
        return _boxResult(jvm, parsed.returnType, result);
      });
    } finally {
      if (ownsLookupClass) lookupClass.release();
    }
  }

  /// [call], typed. Throws a [JniError] if the result is not a `T`.
  T callAs<T>(
    String methodName,
    String signature, [
    List<Object?> args = const [],
  ]) => _cast<T>(call(methodName, signature, args), methodName);

  /// Reads an instance field.
  Object? getField(String fieldName, String descriptor) {
    final lookupClass = _type?.ref ?? jvm.getObjectClass(ref);
    final ownsLookupClass = _type == null;
    try {
      final field = jvm.fieldId(lookupClass, fieldName, descriptor);
      final value = jvm.getFieldByType(descriptor, ref, field, static: false);
      return _boxResult(jvm, descriptor, value);
    } finally {
      if (ownsLookupClass) lookupClass.release();
    }
  }

  /// Writes an instance field.
  void setField(String fieldName, String descriptor, Object? value) {
    final lookupClass = _type?.ref ?? jvm.getObjectClass(ref);
    final ownsLookupClass = _type == null;
    try {
      final field = jvm.fieldId(lookupClass, fieldName, descriptor);
      _withConvertedField(jvm, descriptor, value, (converted) {
        jvm.setFieldByType(descriptor, ref, field, converted, static: false);
      });
    } finally {
      if (ownsLookupClass) lookupClass.release();
    }
  }

  /// The Java `toString()` of this object.
  String? javaToString() => call('toString', '()Ljava/lang/String;') as String?;

  /// Java's `equals`, not reference identity (see [JavaRef.isSameObject]).
  bool javaEquals(JavaObject other) =>
      call('equals', '(Ljava/lang/Object;)Z', [other]) as bool;

  /// Releases the object reference.
  void release() => ref.release();

  @override
  String toString() =>
      isNull ? 'JavaObject(null)' : 'JavaObject(${ref.toString()})';
}

// ---------------------------------------------------------------------------
// Shared conversion helpers
// ---------------------------------------------------------------------------

void _checkArity(JniSignature signature, List<Object?> args, String member) {
  if (args.length != signature.parameterCount) {
    throw JniError(
      '$member$signature expects ${signature.parameterCount} '
      'argument(s), got ${args.length}',
    );
  }
}

/// Converts [args] to `jvalue` slots, runs [body], then releases any temporary
/// `jstring` this created.
///
/// Strings are the reason this exists: passing a Dart `String` means allocating
/// a `java.lang.String` in the VM, which then has to be freed whether the call
/// succeeded or threw.
T _withConvertedArguments<T>(
  Jvm jvm,
  JniSignature signature,
  List<Object?> args,
  T Function(List<JValue> values) body,
) {
  final temporaries = <JavaRef>[];
  try {
    final values = <JValue>[];
    for (var i = 0; i < args.length; i++) {
      values.add(_toJValue(jvm, signature.parameters[i], args[i], temporaries));
    }
    return body(values);
  } finally {
    for (final temporary in temporaries) {
      temporary.release();
    }
  }
}

JValue _toJValue(
  Jvm jvm,
  String descriptor,
  Object? value,
  List<JavaRef> temporaries,
) {
  if (JniType.isReference(descriptor)) {
    if (value == null) return JValue.nullReference;

    if (value is String) {
      final string = jvm.newString(value);
      temporaries.add(string);
      return JValue.fromPointer(string.pointer);
    }
    if (value is JavaObject) return JValue.fromPointer(value.ref.pointer);
    if (value is JavaClass) return JValue.fromPointer(value.ref.pointer);
    if (value is JavaRef) return JValue.fromPointer(value.pointer);
    if (value is Pointer<Void>) return JValue.fromPointer(value);

    throw JniError(
      'cannot pass ${value.runtimeType} as "$descriptor"; '
      'use a String, JavaObject, JavaClass, JavaRef or null',
    );
  }
  return JValue.forDescriptor(descriptor, value);
}

/// Runs [body] with [value] converted for a field write, releasing any
/// temporary `jstring` afterwards.
void _withConvertedField(
  Jvm jvm,
  String descriptor,
  Object? value,
  void Function(Object?) body,
) {
  if (JniType.isReference(descriptor) && value is String) {
    final string = jvm.newString(value);
    try {
      body(string);
    } finally {
      string.release();
    }
    return;
  }
  if (value is JavaObject) {
    body(value.ref);
    return;
  }
  if (value is JavaClass) {
    body(value.ref);
    return;
  }
  body(value);
}

/// Wraps a raw result in the friendliest Dart type for [descriptor].
///
/// `java.lang.String` returns become Dart strings — the overwhelmingly common
/// case, and the one where forgetting to release the reference is easiest.
/// Every other reference becomes a [JavaObject] the caller owns.
Object? _boxResult(Jvm jvm, String descriptor, Object? raw) {
  if (raw is! JavaRef) return raw;

  if (descriptor == JniType.string) {
    try {
      return jvm.stringFrom(raw);
    } finally {
      raw.release();
    }
  }
  return JavaObject(jvm, raw);
}

T _cast<T>(Object? value, String member) {
  if (value is T) return value;
  throw JniError('$member returned ${value.runtimeType}, expected $T');
}

/// `object.getClass().getName()` — the name of an *instance's* runtime class.
String _classNameOf(Jvm jvm, JavaRef object) {
  try {
    final clazz = jvm.getObjectClass(object);
    try {
      return _nameOfClass(jvm, clazz);
    } finally {
      clazz.release();
    }
  } on Object {
    return '<unknown>';
  }
}

/// `clazz.getName()` — the name of a `jclass` that is already in hand.
///
/// Used only for diagnostics, so a failure falls back to a placeholder rather
/// than replacing the caller's real problem with this one.
String _nameOfClass(Jvm jvm, JavaRef clazz) {
  try {
    final classClass = jvm.findClass('java.lang.Class');
    try {
      final getName = jvm.methodId(
        classClass,
        'getName',
        '()Ljava/lang/String;',
      );
      final nameRef = jvm.callObjectMethod(clazz, getName);
      try {
        return jvm.stringFrom(nameRef) ?? '<unknown>';
      } finally {
        nameRef.release();
      }
    } finally {
      classClass.release();
    }
  } on Object {
    return '<unknown>';
  }
}
