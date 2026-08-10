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
