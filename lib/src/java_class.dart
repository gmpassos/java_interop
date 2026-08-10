/// The ergonomic layer: [JavaClass] and [JavaObject].
///
/// The raw extensions on [Jvm] mirror JNI one-to-one, which means the caller
/// has to pick `callIntMethod` vs `callObjectMethod` to match the descriptor —
/// and picking wrong is undefined behaviour, not an error. This layer reads the
/// signature instead and dispatches for you, converts Dart arguments (a
/// `String` into a `jstring`, a `List` into a Java array, a number into its
/// wrapper), and releases the temporaries it creates.
library;

import 'dart:ffi';

import 'boxing.dart';
import 'errors.dart';
import 'java_array.dart';
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
  /// Wraps a `jclass` reference.
  ///
  /// [name] is optional because resolving it means calling `Class.getName()` —
  /// three JNI calls — which is only worth paying for a class that is actually
  /// named in output. Omit it and [name] resolves on first use.
  JavaClass(this.jvm, this.ref, [String? name]) : _name = name;

  final Jvm jvm;

  /// The underlying `jclass` reference.
  final JavaRef ref;

  String? _name;

  /// Member ids resolved through this class so far, keyed by kind, name and
  /// signature.
  ///
  /// A `jmethodID`/`jfieldID` is not a reference and stays valid for as long as
  /// its class is loaded — which [ref] guarantees — so the cache is valid for
  /// exactly this object's lifetime. Without it every call pays for a
  /// `GetMethodID`: two UTF-8 conversions and a lookup in the VM, per
  /// invocation, in a loop that otherwise does no allocation at all.
  final Map<String, Pointer<Void>> _members = {};

  static const _methodKind = 'm';
  static const _staticMethodKind = 'M';
  static const _fieldKind = 'f';
  static const _staticFieldKind = 'F';

  /// The dotted class name, resolved on first use.
  String get name => _name ??= _nameOfClass(jvm, ref);

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

    final constructor = methodId('<init>', signature);

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

    final method = staticMethodId(methodName, signature);

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
    final field = staticFieldId(fieldName, descriptor);
    final value = jvm.getFieldByType(descriptor, ref, field, static: true);
    return _boxResult(jvm, descriptor, value);
  }

  /// Writes a static field.
  ///
  /// A Dart [String], [List] or number is converted the same way a call
  /// argument is, and the temporary released after the write.
  void setStaticField(String fieldName, String descriptor, Object? value) {
    final field = staticFieldId(fieldName, descriptor);
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
    return JavaClass(jvm, superRef);
  }

  /// Whether an instance of [other] can be assigned to this class.
  bool isAssignableFrom(JavaClass other) =>
      jvm.isAssignableFrom(other.ref, ref);

  // --- Member ids ----------------------------------------------------------

  /// Resolves an instance method — or a constructor, as `<init>` returning `V`
  /// — and caches the id on this class.
  Pointer<Void> methodId(String name, String signature) =>
      _memberId(_methodKind, name, signature);

  /// Resolves a static method, cached like [methodId].
  Pointer<Void> staticMethodId(String name, String signature) =>
      _memberId(_staticMethodKind, name, signature);

  /// Resolves an instance field, cached like [methodId]. [descriptor] is a
  /// *type* descriptor, e.g. `I`.
  Pointer<Void> fieldId(String name, String descriptor) =>
      _memberId(_fieldKind, name, descriptor);

  /// Resolves a static field, cached like [methodId].
  Pointer<Void> staticFieldId(String name, String descriptor) =>
      _memberId(_staticFieldKind, name, descriptor);

  /// How many member ids this class has cached, for tests and diagnostics.
  int get cachedMemberCount => _members.length;

  Pointer<Void> _memberId(String kind, String name, String signature) {
    // A method name cannot contain '(' and a field descriptor cannot start
    // with one, so name and signature concatenate without ambiguity.
    final key = '$kind$name$signature';

    final cached = _members[key];
    if (cached != null) return cached;

    final id = switch (kind) {
      _methodKind => jvm.methodId(ref, name, signature),
      _staticMethodKind => jvm.staticMethodId(ref, name, signature),
      _fieldKind => jvm.fieldId(ref, name, signature),
      _ => jvm.staticFieldId(ref, name, signature),
    };
    return _members[key] = id;
  }

  /// Releases the class reference, dropping the member ids cached against it —
  /// they are only valid while the class is held.
  void release() {
    _members.clear();
    ref.release();
  }

  @override
  String toString() => 'JavaClass($name)';
}

/// An instance of a Java class.
class JavaObject {
  JavaObject(this.jvm, this.ref, [JavaClass? type]) : _type = type;

  final Jvm jvm;

  /// The underlying `jobject` reference.
  final JavaRef ref;

  JavaClass? _type;

  /// Whether [_type] was resolved here — and so must be released with this
  /// object — or handed in by a caller who owns it.
  bool _ownsType = false;

  /// `true` when this wraps Java `null`.
  bool get isNull => ref.isNull;

  /// The runtime class, resolved lazily via `Object.getClass()` and then held.
  ///
  /// Holding it is what makes the member-id cache pay off: the cache lives on
  /// the [JavaClass], so an object that resolved its class once resolves each
  /// method id once too, however many times it is called.
  JavaClass get type {
    final known = _type;
    if (known != null) return known;

    _checkNotNull('getClass');
    _ownsType = true;
    return _type = JavaClass(jvm, jvm.getObjectClass(ref));
  }

  /// Calls an instance method. See [JavaClass.callStatic] for the result types.
  Object? call(
    String methodName,
    String signature, [
    List<Object?> args = const [],
  ]) {
    final parsed = JniSignature.parse(signature);
    _checkArity(parsed, args, methodName);
    _checkNotNull(methodName);

    // The method is resolved against the *declared* class when known, so a
    // package-private or overridden method resolves the same way javac would.
    final method = type.methodId(methodName, signature);

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
  }

  /// [call], typed. Throws a [JniError] if the result is not a `T`.
  T callAs<T>(
    String methodName,
    String signature, [
    List<Object?> args = const [],
  ]) => _cast<T>(call(methodName, signature, args), methodName);

  /// Reads an instance field.
  Object? getField(String fieldName, String descriptor) {
    _checkNotNull(fieldName);
    final field = type.fieldId(fieldName, descriptor);
    final value = jvm.getFieldByType(descriptor, ref, field, static: false);
    return _boxResult(jvm, descriptor, value);
  }

  /// Writes an instance field.
  void setField(String fieldName, String descriptor, Object? value) {
    _checkNotNull(fieldName);
    final field = type.fieldId(fieldName, descriptor);
    _withConvertedField(jvm, descriptor, value, (converted) {
      jvm.setFieldByType(descriptor, ref, field, converted, static: false);
    });
  }

  /// Java's `instanceof`.
  bool isInstanceOf(JavaClass clazz) => jvm.isInstanceOf(ref, clazz.ref);

  /// This object as a plain Dart value, when it is one.
  ///
  /// A `java.lang.String` becomes a [String] and a boxed primitive becomes an
  /// `int`, `double` or `bool`; anything else returns `this`. It answers the
  /// question [call] cannot: a method declared to return `Object` — which is
  /// every generic method, after erasure — hands back a [JavaObject], and only
  /// the VM knows what is actually inside it.
  ///
  /// The reference is *not* released, so this object remains yours to release.
  Object? toDart() {
    if (isNull) return null;

    final wrapper = jvm.wrapperOf(ref);
    if (wrapper != null) return jvm.unboxAs(wrapper, ref);
    if (jvm.isJavaString(ref)) return jvm.stringFrom(ref);
    return this;
  }

  /// The Java `toString()` of this object.
  String? javaToString() => call('toString', '()Ljava/lang/String;') as String?;

  /// Java's `equals`, not reference identity (see [JavaRef.isSameObject]).
  bool javaEquals(JavaObject other) =>
      call('equals', '(Ljava/lang/Object;)Z', [other]) as bool;

  /// Releases the object reference, and the runtime class if this object was
  /// the one that resolved it.
  void release() {
    if (_ownsType) {
      _type?.release();
      _type = null;
      _ownsType = false;
    }
    ref.release();
  }

  /// Guards the paths that would otherwise hand a null `jobject` to JNI, where
  /// it is undefined behaviour rather than a `NullPointerException`.
  void _checkNotNull(String member) {
    if (ref.isNull) {
      throw JniError('cannot access "$member" on a Java null');
    }
  }

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

/// Converts [args] to `jvalue` slots, runs [body], then releases every
/// temporary reference this created.
///
/// Temporaries are the reason this exists: passing a Dart `String`, `List` or
/// number means allocating a `java.lang.String`, an array or a wrapper in the
/// VM, each of which has to be freed whether the call succeeded or threw.
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
  if (!JniType.isReference(descriptor)) {
    return JValue.forDescriptor(descriptor, value);
  }
  if (value == null) return JValue.nullReference;
  if (value is Pointer<Void>) return JValue.fromPointer(value);

  return JValue.fromPointer(
    _referenceFor(jvm, descriptor, value, temporaries).pointer,
  );
}

/// The `jobject` to pass for [value] where a [descriptor] is declared.
///
/// Anything allocated on the way is appended to [temporaries], for the caller
/// to release once the call it was built for has returned.
JavaRef _referenceFor(
  Jvm jvm,
  String descriptor,
  Object value,
  List<JavaRef> temporaries,
) {
  if (value is JavaObject) return value.ref;
  if (value is JavaClass) return value.ref;
  if (value is JavaRef) return value;

  final isArray = descriptor.startsWith('[');

  if (value is String && !isArray) {
    final string = jvm.newString(value);
    temporaries.add(string);
    return string;
  }

  if (value is List) {
    if (!isArray) {
      throw JniError(
        'cannot pass a List as "$descriptor"; it is not an array type',
      );
    }
    final array = JavaArray.of(jvm, descriptor.substring(1), value);
    temporaries.add(array.ref);
    return array.ref;
  }

  if ((value is bool || value is int || value is double) &&
      jvm.canBox(descriptor)) {
    final boxed = jvm.box(descriptor, value);
    temporaries.add(boxed);
    return boxed;
  }

  throw JniError(
    'cannot pass ${value.runtimeType} as "$descriptor"; use a String, a List, '
    'a JavaObject, a JavaClass, a JavaRef, a boxable number or null',
  );
}

/// Runs [body] with [value] converted for a field write, releasing any
/// temporary reference afterwards.
void _withConvertedField(
  Jvm jvm,
  String descriptor,
  Object? value,
  void Function(Object?) body,
) {
  if (!JniType.isReference(descriptor)) {
    body(value);
    return;
  }
  if (value == null) {
    body(null);
    return;
  }

  final temporaries = <JavaRef>[];
  try {
    body(_referenceFor(jvm, descriptor, value, temporaries));
  } finally {
    for (final temporary in temporaries) {
      temporary.release();
    }
  }
}

/// Wraps a raw result in the friendliest Dart type for [descriptor].
///
/// The rule is that a *declared* type Dart has a direct equivalent for comes
/// back as that equivalent: `java.lang.String` as a [String], one of the eight
/// primitive wrappers as an `int`/`double`/`bool`, and an array as a
/// [JavaArray] that knows its own element type. These are also the cases where
/// forgetting to release the reference is easiest. Every other reference
/// becomes a [JavaObject] the caller owns — call [JavaObject.toDart] on it when
/// the declared type was `Object` but the contents might not be.
Object? _boxResult(Jvm jvm, String descriptor, Object? raw) {
  if (raw is! JavaRef) return raw;

  if (descriptor == JniType.string) {
    try {
      return jvm.stringFrom(raw);
    } finally {
      raw.release();
    }
  }

  if (descriptor.startsWith('[')) {
    return JavaArray(jvm, raw, descriptor.substring(1));
  }

  final wrapper = JavaWrapper.forDescriptor(descriptor);
  if (wrapper != null) {
    try {
      return jvm.unboxAs(wrapper, raw);
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
