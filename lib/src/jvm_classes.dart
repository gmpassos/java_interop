/// Class, method and field resolution.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';
import 'signatures.dart';

/// Looking up classes and their members.
extension JvmClasses on Jvm {
  /// Finds a class by name.
  ///
  /// Accepts either form — `java.lang.String` or `java/lang/String` — because
  /// JNI wants slashes but every other Java-facing API prints dots, and having
  /// to remember which is which at each call site is a reliable source of
  /// typos. Nested classes keep their `$`: `com.example.Outer$Inner`.
  ///
  /// The returned reference is *local*; release it, or scope it in a
  /// [JvmLocalFrames.localFrame].
  JavaRef findClass(String name) {
    final jniName = JniType.classNameToJni(name);
    final env = this.env;

    final fn = Jvm.fnSlotOf(
      env,
      JniFn.findClass,
    ).cast<NativeFunction<FindClassC>>().asFunction<FindClassDart>();

    final clazz = using(
      (arena) => fn(env, jniName.toNativeUtf8(allocator: arena)),
    );

    // FindClass raises NoClassDefFoundError, which must be cleared before the
    // next call; translating it to a lookup error keeps the message actionable.
    if (clazz == nullptr) {
      try {
        checkException();
      } on JavaException catch (_) {
        throw JniLookupError('class', JniType.classNameToDotted(name));
      }
      throw JniLookupError('class', JniType.classNameToDotted(name));
    }
    return JavaRef(this, clazz, JavaRefKind.local);
  }

  /// The runtime class of [object] (`Object.getClass()`).
  JavaRef getObjectClass(JavaRef object) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.getObjectClass,
    ).cast<NativeFunction<RefC>>().asFunction<RefDart>();
    final clazz = fn(env, object.pointer);
    checkException();
    return JavaRef(this, clazz, JavaRefKind.local);
  }

  /// The superclass of [clazz], or a `null` handle for `Object`/interfaces.
  JavaRef getSuperclass(JavaRef clazz) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.getSuperclass,
    ).cast<NativeFunction<RefC>>().asFunction<RefDart>();
    final superclass = fn(env, clazz.pointer);
    checkException();
    return JavaRef(this, superclass, JavaRefKind.local);
  }

  /// Java's `instanceof`.
  bool isInstanceOf(JavaRef object, JavaRef clazz) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.isInstanceOf,
    ).cast<NativeFunction<IsInstanceOfC>>().asFunction<IsInstanceOfDart>();
    final result = fn(env, object.pointer, clazz.pointer) != 0;
    checkException();
    return result;
  }

  /// `to.isAssignableFrom(from)` — whether a `from` can be used as a `to`.
  bool isAssignableFrom(JavaRef from, JavaRef to) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.isAssignableFrom,
    ).cast<NativeFunction<IsInstanceOfC>>().asFunction<IsInstanceOfDart>();
    final result = fn(env, from.pointer, to.pointer) != 0;
    checkException();
    return result;
  }

  /// Resolves an instance method (or a constructor, as `<init>` returning `V`).
  ///
  /// The returned `jmethodID` is *not* a reference — it needs no release and
  /// stays valid as long as the class is loaded.
  Pointer<Void> methodId(JavaRef clazz, String name, String signature) =>
      _memberId(JniFn.getMethodId, clazz, name, signature, 'method');

  /// Resolves a static method.
  Pointer<Void> staticMethodId(JavaRef clazz, String name, String signature) =>
      _memberId(
        JniFn.getStaticMethodId,
        clazz,
        name,
        signature,
        'static method',
      );

  /// Resolves an instance field. [signature] is a *type* descriptor, e.g. `I`.
  Pointer<Void> fieldId(JavaRef clazz, String name, String signature) =>
      _memberId(JniFn.getFieldId, clazz, name, signature, 'field');

  /// Resolves a static field.
  Pointer<Void> staticFieldId(JavaRef clazz, String name, String signature) =>
      _memberId(JniFn.getStaticFieldId, clazz, name, signature, 'static field');

  Pointer<Void> _memberId(
    int slot,
    JavaRef clazz,
    String name,
    String signature,
    String kind,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<MemberIdC>>().asFunction<MemberIdDart>();

    final id = using(
      (arena) => fn(
        env,
        clazz.pointer,
        name.toNativeUtf8(allocator: arena),
        signature.toNativeUtf8(allocator: arena),
      ),
    );

    if (id == nullptr) {
      // NoSuchMethodError / NoSuchFieldError is pending; clear it so the next
      // call is not poisoned, then report the descriptor that failed.
      try {
        checkException();
      } on JavaException catch (_) {
        // Expected: replaced by the more precise lookup error below.
      }
      throw JniLookupError(kind, name, signature);
    }
    return id;
  }

  /// Throws a new Java exception of [className] with [message].
  ///
  /// The exception becomes *pending* on the current thread, exactly as if Java
  /// code had thrown it. This binding immediately converts it into a Dart
  /// [JavaException] so the two worlds do not disagree about who is throwing.
  Never throwJava(String className, [String message = '']) {
    final clazz = findClass(className);
    try {
      final env = this.env;
      final fn = Jvm.fnSlotOf(
        env,
        JniFn.throwNew,
      ).cast<NativeFunction<ThrowNewC>>().asFunction<ThrowNewDart>();

      final rc = using(
        (arena) =>
            fn(env, clazz.pointer, message.toNativeUtf8(allocator: arena)),
      );
      if (rc != JniResult.ok) {
        throw JniError(
          'ThrowNew($className) failed: '
          '${JniResult.describe(rc)}',
        );
      }

      checkException();
      throw JniError('ThrowNew($className) left no pending exception');
    } finally {
      clazz.release();
    }
  }
}
