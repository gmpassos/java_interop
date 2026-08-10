/// Constructor and method invocation, for every JNI return type.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvalue.dart';
import 'jvm.dart';
import 'native_types.dart';
import 'signatures.dart';

/// Packs [args] into a `jvalue[]` inside [arena], or `nullptr` when empty.
Pointer<Int64> packArguments(List<JValue> args, Arena arena) {
  if (args.isEmpty) return nullptr;
  final array = arena<Int64>(args.length);
  for (var i = 0; i < args.length; i++) {
    array[i] = args[i].bits;
  }
  return array;
}

/// Invoking constructors and methods.
///
/// Each `call…` name states the *return* type, matching JNI's own
/// `Call<Type>Method` naming: pick the one that matches the method's
/// descriptor. Calling the wrong one is undefined behaviour in JNI, so the
/// higher-level [JavaObject]-style API derives it from the signature instead.
extension JvmCalls on Jvm {
  /// Invokes a constructor resolved with `methodId(clazz, '<init>', …)`.
  JavaRef newObject(
    JavaRef clazz,
    Pointer<Void> constructor, [
    List<JValue> args = const [],
  ]) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.newObjectA,
    ).cast<NativeFunction<CallObjectAC>>().asFunction<CallObjectADart>();

    final object = using(
      (arena) =>
          fn(env, clazz.pointer, constructor, packArguments(args, arena)),
    );
    checkException();
    return JavaRef(this, object, JavaRefKind.local);
  }

  // --- Instance calls ------------------------------------------------------

  JavaRef callObjectMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => JavaRef(
    this,
    _callObject(JniFn.callObjectMethodA, object.pointer, method, args),
    JavaRefKind.local,
  );

  bool callBooleanMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callBool(JniFn.callBooleanMethodA, object.pointer, method, args);

  int callByteMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callByte(JniFn.callByteMethodA, object.pointer, method, args);

  int callCharMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callChar(JniFn.callCharMethodA, object.pointer, method, args);

  int callShortMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callShort(JniFn.callShortMethodA, object.pointer, method, args);

  int callIntMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callInt(JniFn.callIntMethodA, object.pointer, method, args);

  int callLongMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callLong(JniFn.callLongMethodA, object.pointer, method, args);

  double callFloatMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callFloat(JniFn.callFloatMethodA, object.pointer, method, args);

  double callDoubleMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callDouble(JniFn.callDoubleMethodA, object.pointer, method, args);

  void callVoidMethod(
    JavaRef object,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callVoid(JniFn.callVoidMethodA, object.pointer, method, args);

  // --- Static calls --------------------------------------------------------

  JavaRef callStaticObjectMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => JavaRef(
    this,
    _callObject(JniFn.callStaticObjectMethodA, clazz.pointer, method, args),
    JavaRefKind.local,
  );

  bool callStaticBooleanMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callBool(JniFn.callStaticBooleanMethodA, clazz.pointer, method, args);

  int callStaticByteMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callByte(JniFn.callStaticByteMethodA, clazz.pointer, method, args);

  int callStaticCharMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callChar(JniFn.callStaticCharMethodA, clazz.pointer, method, args);

  int callStaticShortMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callShort(JniFn.callStaticShortMethodA, clazz.pointer, method, args);

  int callStaticIntMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callInt(JniFn.callStaticIntMethodA, clazz.pointer, method, args);

  int callStaticLongMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callLong(JniFn.callStaticLongMethodA, clazz.pointer, method, args);

  double callStaticFloatMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callFloat(JniFn.callStaticFloatMethodA, clazz.pointer, method, args);

  double callStaticDoubleMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callDouble(JniFn.callStaticDoubleMethodA, clazz.pointer, method, args);

  void callStaticVoidMethod(
    JavaRef clazz,
    Pointer<Void> method, [
    List<JValue> args = const [],
  ]) => _callVoid(JniFn.callStaticVoidMethodA, clazz.pointer, method, args);

  // --- Dispatch by return descriptor ---------------------------------------

  /// Calls [method] and returns its result boxed as the natural Dart type for
  /// [returnType]: `bool`, `int`, `double`, `JavaRef`, or `null` for `void`.
  ///
  /// This is what lets the ergonomic layer work from a signature string alone
  /// instead of making the caller pick the right `call…` variant.
  Object? callByReturnType(
    String returnType,
    JavaRef receiver,
    Pointer<Void> method,
    List<JValue> args, {
    required bool static,
  }) {
    switch (returnType) {
      case JniType.void_:
        static
            ? callStaticVoidMethod(receiver, method, args)
            : callVoidMethod(receiver, method, args);
        return null;
      case JniType.boolean:
        return static
            ? callStaticBooleanMethod(receiver, method, args)
            : callBooleanMethod(receiver, method, args);
      case JniType.byte:
        return static
            ? callStaticByteMethod(receiver, method, args)
            : callByteMethod(receiver, method, args);
      case JniType.char:
        return static
            ? callStaticCharMethod(receiver, method, args)
            : callCharMethod(receiver, method, args);
      case JniType.short:
        return static
            ? callStaticShortMethod(receiver, method, args)
            : callShortMethod(receiver, method, args);
      case JniType.int_:
        return static
            ? callStaticIntMethod(receiver, method, args)
            : callIntMethod(receiver, method, args);
      case JniType.long:
        return static
            ? callStaticLongMethod(receiver, method, args)
            : callLongMethod(receiver, method, args);
      case JniType.float:
        return static
            ? callStaticFloatMethod(receiver, method, args)
            : callFloatMethod(receiver, method, args);
      case JniType.double_:
        return static
            ? callStaticDoubleMethod(receiver, method, args)
            : callDoubleMethod(receiver, method, args);
      default:
        if (!JniType.isReference(returnType)) {
          throw JniError('unknown return descriptor "$returnType"');
        }
        return static
            ? callStaticObjectMethod(receiver, method, args)
            : callObjectMethod(receiver, method, args);
    }
  }

  // --- Internals -----------------------------------------------------------

  Pointer<Void> _callObject(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallObjectAC>>().asFunction<CallObjectADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  bool _callBool(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallBoolAC>>().asFunction<CallBoolADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result != 0;
  }

  int _callByte(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallByteAC>>().asFunction<CallByteADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  int _callChar(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallCharAC>>().asFunction<CallCharADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  int _callShort(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallShortAC>>().asFunction<CallShortADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  int _callInt(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallIntAC>>().asFunction<CallIntADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  int _callLong(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallLongAC>>().asFunction<CallLongADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  double _callFloat(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallFloatAC>>().asFunction<CallFloatADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  double _callDouble(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallDoubleAC>>().asFunction<CallDoubleADart>();
    final result = using(
      (arena) => fn(env, receiver, method, packArguments(args, arena)),
    );
    checkException();
    return result;
  }

  void _callVoid(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> method,
    List<JValue> args,
  ) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      slot,
    ).cast<NativeFunction<CallVoidAC>>().asFunction<CallVoidADart>();
    using((arena) => fn(env, receiver, method, packArguments(args, arena)));
    checkException();
  }
}
