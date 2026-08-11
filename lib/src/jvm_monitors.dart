/// Java's `synchronized`, from Dart.
library;

import 'dart:ffi';

import 'errors.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';

/// Entering and leaving a Java object's monitor.
///
/// The same lock `synchronized` uses, so Dart and Java code contend correctly
/// with each other rather than each thinking it holds the object alone. Worth
/// reaching for in two situations: when Java code on other threads reads state
/// this isolate is changing, and when a Dart proxy handler runs inside a Java
/// library that expects its callbacks to be serialised.
extension JvmMonitors on Jvm {
  /// Runs [body] holding [target]'s monitor, releasing it on the way out.
  ///
  /// Exactly Java's `synchronized (target) { … }`, including reentrancy: the same
  /// thread may enter a monitor it already holds.
  ///
  /// ```dart
  /// jvm.synchronized(sharedList, () {
  ///   sharedList.callJava('boolean add(Object)', [item]);
  /// });
  /// ```
  ///
  /// **Do not `await` inside [body].** A monitor belongs to the OS thread that
  /// entered it, and an isolate can resume on a different thread after an
  /// `await` — which would leave the monitor held by a thread that has moved on,
  /// and `MonitorExit` on the wrong thread throws
  /// `IllegalMonitorStateException`. This signature is synchronous so the mistake
  /// is hard to make by accident.
  T synchronized<T>(Object target, T Function() body) {
    final ref = _refOf(target);
    monitorEnter(ref);
    try {
      return body();
    } finally {
      monitorExit(ref);
    }
  }

  /// Enters [target]'s monitor, blocking until it is free.
  ///
  /// Prefer [synchronized], which cannot forget the exit.
  void monitorEnter(JavaRef target) {
    if (target.isNull) {
      throw JniError('cannot enter the monitor of a null reference');
    }
    final env = this.env;
    final rc = Jvm.fnSlotOf(env, JniFn.monitorEnter)
        .cast<NativeFunction<MonitorC>>()
        .asFunction<MonitorDart>()(env, target.pointer);
    if (rc != JniResult.ok) {
      checkException();
      throw JniError('MonitorEnter failed: ${JniResult.describe(rc)}');
    }
  }

  /// Leaves [target]'s monitor.
  ///
  /// Must run on the thread that entered it, and as many times as it entered.
  void monitorExit(JavaRef target) {
    if (target.isNull) {
      throw JniError('cannot exit the monitor of a null reference');
    }
    final env = this.env;
    final rc = Jvm.fnSlotOf(env, JniFn.monitorExit)
        .cast<NativeFunction<MonitorC>>()
        .asFunction<MonitorDart>()(env, target.pointer);
    if (rc != JniResult.ok) {
      checkException();
      throw JniError('MonitorExit failed: ${JniResult.describe(rc)}');
    }
  }
}

/// The reference underneath a [JavaRef], [JavaObject] or [JavaClass].
JavaRef _refOf(Object target) {
  if (target is JavaRef) return target;
  if (target is JavaObject) return target.ref;
  if (target is JavaClass) return target.ref;
  throw JniError(
    'not a Java reference: ${target.runtimeType}. Pass a JavaRef, JavaObject '
    'or JavaClass',
  );
}
