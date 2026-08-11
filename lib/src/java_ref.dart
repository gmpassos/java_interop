/// Owned handles to Java references.
///
/// JNI hands back *local* references that belong to the current thread and are
/// freed when the native frame returns — except there is no native frame here,
/// so in a long-running Dart isolate they accumulate until the local reference
/// table overflows. These wrappers make ownership explicit: every handle is
/// released with [JavaRef.release], or scoped with [Jvm.localFrame].
library;

import 'dart:ffi';

import 'errors.dart';
import 'java_class.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';

/// Whether a reference is local (thread- and frame-scoped) or global (valid
/// until explicitly deleted, on any thread).
enum JavaRefKind {
  local,
  global;

  bool get isGlobal => this == JavaRefKind.global;
}

/// A handle to a Java object.
///
/// Use-after-release throws a [JniError] rather than passing a dangling pointer
/// to the VM, which would be an undebuggable crash.
class JavaRef {
  JavaRef(this.jvm, Pointer<Void> pointer, this.kind) : _pointer = pointer;

  final Jvm jvm;

  /// Whether this handle owns a local or a global reference.
  final JavaRefKind kind;

  Pointer<Void> _pointer;
  bool _released = false;

  /// The raw `jobject`.
  Pointer<Void> get pointer {
    if (_released) {
      throw JniError('use of a $kind reference after release()');
    }
    return _pointer;
  }

  /// `true` when this handle wraps Java `null`.
  bool get isNull => !_released && _pointer == nullptr;

  /// `true` once [release] has run.
  bool get isReleased => _released;

  /// Promotes this reference to a global one, which survives the current
  /// thread and frame.
  ///
  /// The receiver is left untouched; release both when done.
  JavaRef toGlobal() {
    final env = jvm.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.newGlobalRef,
    ).cast<NativeFunction<RefC>>().asFunction<RefDart>();
    return JavaRef(jvm, fn(env, pointer), JavaRefKind.global);
  }

  /// Creates a new local reference to the same object.
  JavaRef toLocal() {
    final env = jvm.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.newLocalRef,
    ).cast<NativeFunction<RefC>>().asFunction<RefDart>();
    return JavaRef(jvm, fn(env, pointer), JavaRefKind.local);
  }

  /// `true` when both handles refer to the same Java object (or both are
  /// `null`). Reference identity, i.e. Java's `==`, not `equals`.
  bool isSameObject(JavaRef other) {
    final env = jvm.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.isSameObject,
    ).cast<NativeFunction<IsSameObjectC>>().asFunction<IsSameObjectDart>();
    return fn(env, pointer, other.pointer) != 0;
  }

  /// Releases the underlying reference. Idempotent, and safe on a `null` ref.
  void release() {
    if (_released) return;
    _released = true;

    if (_pointer == nullptr) return;

    final env = jvm.env;
    final slot = kind.isGlobal ? JniFn.deleteGlobalRef : JniFn.deleteLocalRef;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<DeleteRefC>>()
        .asFunction<DeleteRefDart>()(env, _pointer);

    _pointer = nullptr;
  }

  @override
  String toString() => _released
      ? 'JavaRef(released)'
      : 'JavaRef(${kind.name}, 0x${_pointer.address.toRadixString(16)})';
}

/// Scoped local-reference management.
extension JvmLocalFrames on Jvm {
  /// Runs [body] inside a JNI local frame, freeing every local reference it
  /// created on the way out.
  ///
  /// The cheap way to call Java in a loop without leaking. A [JavaRef] the body
  /// wants to keep must be promoted with [JavaRef.toGlobal] first — locals do
  /// not survive the frame.
  T localFrame<T>(T Function() body, {int capacity = 16}) {
    final env = this.env;

    final push = Jvm.fnSlotOf(
      env,
      JniFn.pushLocalFrame,
    ).cast<NativeFunction<PushLocalFrameC>>().asFunction<PushLocalFrameDart>();
    if (push(env, capacity) != JniResult.ok) {
      checkException();
      throw JniError('PushLocalFrame($capacity) failed');
    }

    try {
      return body();
    } finally {
      // Re-resolve: `body` may have awaited nothing, but staying honest here
      // costs one table read.
      final popEnv = this.env;
      Jvm.fnSlotOf(popEnv, JniFn.popLocalFrame)
          .cast<NativeFunction<PopLocalFrameC>>()
          .asFunction<PopLocalFrameDart>()(popEnv, nullptr);
    }
  }

  /// Runs [body] inside a local frame and lets it **return one reference**,
  /// which survives into the enclosing frame.
  ///
  /// This is [localFrame] for the case it cannot serve: building something worth
  /// keeping. `PopLocalFrame` takes a result reference and hands back an
  /// equivalent one owned by the outer frame, and that is what this uses — so the
  /// returned [JavaRef] is a valid *local* reference of the caller's frame.
  /// Promote it with [JavaRef.toGlobal] if it needs to outlive that too.
  ///
  /// Why it exists: returning a reference from [localFrame] compiles, runs, and
  /// yields a **dangling handle** — the frame freed it on the way out. Nothing
  /// reports it; the next use is undefined behaviour, which in practice means a
  /// crash somewhere unrelated. The workaround is to call [JavaRef.toGlobal]
  /// *inside* the body and return that, which every call site has to remember.
  ///
  /// ```dart
  /// // A compiled report worth caching for the process.
  /// final report = jvm.localFrameReturning(() {
  ///   final design = loader.callJavaAs<JavaObject>('JasperDesign load(...)');
  ///   return compiler.callJavaAs<JavaObject>('JasperReport compile(...)').ref;
  /// }, capacity: 128).toGlobal();
  /// ```
  ///
  /// [body] returning `null` is allowed and pops the frame with no result.
  JavaRef? localFrameReturning(JavaRef? Function() body, {int capacity = 16}) {
    final env = this.env;

    final push = Jvm.fnSlotOf(
      env,
      JniFn.pushLocalFrame,
    ).cast<NativeFunction<PushLocalFrameC>>().asFunction<PushLocalFrameDart>();
    if (push(env, capacity) != JniResult.ok) {
      checkException();
      throw JniError('PushLocalFrame($capacity) failed');
    }

    JavaRef? result;
    var popped = false;
    try {
      result = body();

      final popEnv = this.env;
      final promoted = Jvm.fnSlotOf(popEnv, JniFn.popLocalFrame)
          .cast<NativeFunction<PopLocalFrameC>>()
          .asFunction<PopLocalFrameDart>()(popEnv, result?.pointer ?? nullptr);
      popped = true;

      if (result == null || promoted == nullptr) return null;
      return JavaRef(this, promoted, JavaRefKind.local);
    } finally {
      // `body` threw, or the pop itself did: the frame still has to go.
      if (!popped) {
        final popEnv = this.env;
        Jvm.fnSlotOf(popEnv, JniFn.popLocalFrame)
            .cast<NativeFunction<PopLocalFrameC>>()
            .asFunction<PopLocalFrameDart>()(popEnv, nullptr);
      }
    }
  }

  /// [localFrameReturning] for the common case of building a [JavaObject].
  ///
  /// ```dart
  /// final context = jvm.localFrameReturningObject(() {
  ///   final ctx = contextClass.newJava('()');
  ///   ctx.callJava('void setProperty(String, String)', ['k', 'v']);
  ///   return ctx;
  /// });
  /// ```
  ///
  /// The result resolves its own [JavaObject.type] on demand rather than
  /// inheriting the one [body] may have had. That is deliberate: a `JavaClass`
  /// resolved inside the frame holds a frame-local reference of its own, so
  /// carrying it out would hand back a class that is already dangling. Pass a
  /// globally-held class explicitly if the member-id cache matters.
  JavaObject? localFrameReturningObject(
    JavaObject? Function() body, {
    int capacity = 16,
    JavaClass? type,
  }) {
    final ref = localFrameReturning(() => body()?.ref, capacity: capacity);
    if (ref == null) return null;
    return JavaObject(this, ref, type);
  }

  /// Hints the VM that [capacity] local references are about to be created.
  void ensureLocalCapacity(int capacity) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.ensureLocalCapacity,
    ).cast<NativeFunction<PushLocalFrameC>>().asFunction<PushLocalFrameDart>();
    if (fn(env, capacity) != JniResult.ok) checkException();
  }
}
