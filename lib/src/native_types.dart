/// `dart:ffi` typedefs and structs mirroring `jni.h`.
///
/// Only the `…A` call variants are bound. The bare `CallObjectMethod` family is
/// C variadic, and arm64 (macOS and Linux) passes variadic arguments under a
/// different calling convention than fixed ones — calling them through a
/// non-variadic FFI signature would silently corrupt arguments. The `A`
/// variants take a `jvalue*` array instead and are correct everywhere.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// --- Invocation API (exported symbols in libjvm) ---------------------------

typedef CreateJavaVmC =
    Int32 Function(
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Void>,
    );
typedef CreateJavaVmDart =
    int Function(Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Void>);

typedef GetCreatedJavaVmsC =
    Int32 Function(Pointer<Pointer<Void>>, Int32, Pointer<Int32>);
typedef GetCreatedJavaVmsDart =
    int Function(Pointer<Pointer<Void>>, int, Pointer<Int32>);

// --- JavaVM function table -------------------------------------------------

typedef VmIntC = Int32 Function(Pointer<Void>);
typedef VmIntDart = int Function(Pointer<Void>);

typedef GetEnvC = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>, Int32);
typedef GetEnvDart = int Function(Pointer<Void>, Pointer<Pointer<Void>>, int);

typedef AttachThreadC =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Void>);
typedef AttachThreadDart =
    int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Void>);

// --- JNIEnv function table -------------------------------------------------

typedef EnvIntC = Int32 Function(Pointer<Void>);
typedef EnvIntDart = int Function(Pointer<Void>);

typedef EnvVoidC = Void Function(Pointer<Void>);
typedef EnvVoidDart = void Function(Pointer<Void>);

typedef EnvUint8C = Uint8 Function(Pointer<Void>);
typedef EnvUint8Dart = int Function(Pointer<Void>);

typedef EnvObjectC = Pointer<Void> Function(Pointer<Void>);
typedef EnvObjectDart = Pointer<Void> Function(Pointer<Void>);

typedef FindClassC = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef FindClassDart = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);

typedef MemberIdC =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );
typedef MemberIdDart =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );

typedef ThrowNewC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>);
typedef ThrowNewDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>);

typedef ThrowC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef ThrowDart = int Function(Pointer<Void>, Pointer<Void>);

/// `Call<Type>MethodA`, `CallStatic<Type>MethodA` and `NewObjectA` all share
/// this shape: `(env, receiver, methodId, jvalue*)`.
typedef CallObjectAC =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Int64>,
    );
typedef CallObjectADart =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Int64>,
    );

typedef CallBoolAC =
    Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallBoolADart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

typedef CallByteAC =
    Int8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallByteADart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

typedef CallCharAC =
    Uint16 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Int64>,
    );
typedef CallCharADart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

typedef CallShortAC =
    Int16 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallShortADart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

typedef CallIntAC =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallIntADart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

typedef CallLongAC =
    Int64 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallLongADart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

typedef CallFloatAC =
    Float Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallFloatADart =
    double Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Int64>,
    );

typedef CallDoubleAC =
    Double Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Int64>,
    );
typedef CallDoubleADart =
    double Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Int64>,
    );

typedef CallVoidAC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);
typedef CallVoidADart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int64>);

// --- Fields ----------------------------------------------------------------

typedef GetObjectFieldC =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetObjectFieldDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetBoolFieldC =
    Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetBoolFieldDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetByteFieldC =
    Int8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetByteFieldDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetCharFieldC =
    Uint16 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetCharFieldDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetShortFieldC =
    Int16 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetShortFieldDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetIntFieldC =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetIntFieldDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetLongFieldC =
    Int64 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetLongFieldDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetFloatFieldC =
    Float Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetFloatFieldDart =
    double Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef GetDoubleFieldC =
    Double Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef GetDoubleFieldDart =
    double Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef SetObjectFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef SetObjectFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef SetBoolFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint8);
typedef SetBoolFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef SetByteFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int8);
typedef SetByteFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef SetCharFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint16);
typedef SetCharFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef SetShortFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int16);
typedef SetShortFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef SetIntFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int32);
typedef SetIntFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef SetLongFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int64);
typedef SetLongFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

typedef SetFloatFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Float);
typedef SetFloatFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, double);

typedef SetDoubleFieldC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Double);
typedef SetDoubleFieldDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, double);

// --- Static fields (same shapes, but the receiver is a jclass) --------------
// Reuse the instance typedefs above; the C signatures are identical.

// --- Strings ---------------------------------------------------------------

typedef NewStringC =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, Int32);
typedef NewStringDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, int);

typedef GetStringLengthC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef GetStringLengthDart = int Function(Pointer<Void>, Pointer<Void>);

typedef GetStringCharsC =
    Pointer<Uint16> Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>);
typedef GetStringCharsDart =
    Pointer<Uint16> Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>);

typedef ReleaseStringCharsC =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>);
typedef ReleaseStringCharsDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>);

// --- References ------------------------------------------------------------

typedef RefC = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef RefDart = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);

typedef DeleteRefC = Void Function(Pointer<Void>, Pointer<Void>);
typedef DeleteRefDart = void Function(Pointer<Void>, Pointer<Void>);

typedef IsSameObjectC =
    Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef IsSameObjectDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef IsInstanceOfC =
    Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef IsInstanceOfDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

typedef PushLocalFrameC = Int32 Function(Pointer<Void>, Int32);
typedef PushLocalFrameDart = int Function(Pointer<Void>, int);

typedef PopLocalFrameC = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef PopLocalFrameDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);

// --- Arrays ----------------------------------------------------------------

typedef GetArrayLengthC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef GetArrayLengthDart = int Function(Pointer<Void>, Pointer<Void>);

typedef NewPrimitiveArrayC = Pointer<Void> Function(Pointer<Void>, Int32);
typedef NewPrimitiveArrayDart = Pointer<Void> Function(Pointer<Void>, int);

typedef NewObjectArrayC =
    Pointer<Void> Function(Pointer<Void>, Int32, Pointer<Void>, Pointer<Void>);
typedef NewObjectArrayDart =
    Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>, Pointer<Void>);

typedef GetObjectArrayElementC =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Int32);
typedef GetObjectArrayElementDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int);

typedef SetObjectArrayElementC =
    Void Function(Pointer<Void>, Pointer<Void>, Int32, Pointer<Void>);
typedef SetObjectArrayElementDart =
    void Function(Pointer<Void>, Pointer<Void>, int, Pointer<Void>);

/// `Get<Type>ArrayRegion` / `Set<Type>ArrayRegion`:
/// `(env, array, start, len, buffer)`. The buffer element type differs per
/// primitive, so this is bound as an opaque pointer and cast at the call site.
typedef ArrayRegionC =
    Void Function(Pointer<Void>, Pointer<Void>, Int32, Int32, Pointer<Void>);
typedef ArrayRegionDart =
    void Function(Pointer<Void>, Pointer<Void>, int, int, Pointer<Void>);

// --- Structs ---------------------------------------------------------------

/// `JavaVMOption` from jni.h.
final class JavaVMOption extends Struct {
  external Pointer<Utf8> optionString;
  external Pointer<Void> extraInfo;
}

/// `JavaVMInitArgs` from jni.h.
final class JavaVMInitArgs extends Struct {
  @Int32()
  external int version;
  @Int32()
  external int nOptions;
  external Pointer<JavaVMOption> options;

  /// `jboolean`, i.e. `unsigned char`.
  @Uint8()
  external int ignoreUnrecognized;
}
