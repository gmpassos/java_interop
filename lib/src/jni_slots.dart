/// Indices into the two JNI function tables.
///
/// `JNIEnv*` and `JavaVM*` are each a pointer to a pointer to a table of
/// function pointers. There are no exported symbols to look up — apart from
/// `JNI_CreateJavaVM` and `JNI_GetCreatedJavaVMs` — so every call means
/// dereferencing to the table, indexing the right slot, and casting that slot
/// to the right signature.
///
/// These indices were extracted from `$JAVA_HOME/include/jni.h` of OpenJDK 21
/// by numbering the members of `struct JNINativeInterface_` (235 slots,
/// including the four leading `reserved` entries) rather than transcribed by
/// hand. The table is append-only across JNI versions, so they are valid for
/// any JNI >= 1.6 VM.
library;

/// Slots in `struct JNINativeInterface_`, reached through `JNIEnv*`.
abstract final class JniFn {
  static const getVersion = 4;
  static const defineClass = 5;
  static const findClass = 6;

  static const getSuperclass = 10;
  static const isAssignableFrom = 11;

  static const throw_ = 13;
  static const throwNew = 14;
  static const exceptionOccurred = 15;
  static const exceptionDescribe = 16;
  static const exceptionClear = 17;

  static const pushLocalFrame = 19;
  static const popLocalFrame = 20;
  static const newGlobalRef = 21;
  static const deleteGlobalRef = 22;
  static const deleteLocalRef = 23;
  static const isSameObject = 24;
  static const newLocalRef = 25;
  static const ensureLocalCapacity = 26;

  static const newObjectA = 30;
  static const getObjectClass = 31;
  static const isInstanceOf = 32;
  static const getMethodId = 33;

  // Call<Type>MethodA — instance calls. The table groups each type as
  // (…Method, …MethodV, …MethodA), so the `A` variants are 3 apart.
  static const callObjectMethodA = 36;
  static const callBooleanMethodA = 39;
  static const callByteMethodA = 42;
  static const callCharMethodA = 45;
  static const callShortMethodA = 48;
  static const callIntMethodA = 51;
  static const callLongMethodA = 54;
  static const callFloatMethodA = 57;
  static const callDoubleMethodA = 60;
  static const callVoidMethodA = 63;

  static const getFieldId = 94;
  static const getObjectField = 95;
  static const getBooleanField = 96;
  static const getByteField = 97;
  static const getCharField = 98;
  static const getShortField = 99;
  static const getIntField = 100;
  static const getLongField = 101;
  static const getFloatField = 102;
  static const getDoubleField = 103;
  static const setObjectField = 104;
  static const setBooleanField = 105;
  static const setByteField = 106;
  static const setCharField = 107;
  static const setShortField = 108;
  static const setIntField = 109;
  static const setLongField = 110;
  static const setFloatField = 111;
  static const setDoubleField = 112;

  static const getStaticMethodId = 113;
  static const callStaticObjectMethodA = 116;
  static const callStaticBooleanMethodA = 119;
  static const callStaticByteMethodA = 122;
  static const callStaticCharMethodA = 125;
  static const callStaticShortMethodA = 128;
  static const callStaticIntMethodA = 131;
  static const callStaticLongMethodA = 134;
  static const callStaticFloatMethodA = 137;
  static const callStaticDoubleMethodA = 140;
  static const callStaticVoidMethodA = 143;

  static const getStaticFieldId = 144;
  static const getStaticObjectField = 145;
  static const getStaticBooleanField = 146;
  static const getStaticByteField = 147;
  static const getStaticCharField = 148;
  static const getStaticShortField = 149;
  static const getStaticIntField = 150;
  static const getStaticLongField = 151;
  static const getStaticFloatField = 152;
  static const getStaticDoubleField = 153;
  static const setStaticObjectField = 154;
  static const setStaticBooleanField = 155;
  static const setStaticByteField = 156;
  static const setStaticCharField = 157;
  static const setStaticShortField = 158;
  static const setStaticIntField = 159;
  static const setStaticLongField = 160;
  static const setStaticFloatField = 161;
  static const setStaticDoubleField = 162;

  // Strings. The UTF-16 (`GetStringChars`) family is used rather than the
  // UTF-8 one: `NewStringUTF`/`GetStringUTFChars` speak *modified* UTF-8, which
  // encodes U+0000 as two bytes and astral characters as surrogate pairs of
  // three bytes each. Dart strings are already UTF-16, so the `jchar` family is
  // both exact and cheaper.
  static const newString = 163;
  static const getStringLength = 164;
  static const getStringChars = 165;
  static const releaseStringChars = 166;
  static const newStringUtf = 167;
  static const getStringUtfLength = 168;
  static const getStringUtfChars = 169;
  static const releaseStringUtfChars = 170;

  static const getArrayLength = 171;
  static const newObjectArray = 172;
  static const getObjectArrayElement = 173;
  static const setObjectArrayElement = 174;

  static const newBooleanArray = 175;
  static const newByteArray = 176;
  static const newCharArray = 177;
  static const newShortArray = 178;
  static const newIntArray = 179;
  static const newLongArray = 180;
  static const newFloatArray = 181;
  static const newDoubleArray = 182;

  static const getBooleanArrayRegion = 199;
  static const getByteArrayRegion = 200;
  static const getCharArrayRegion = 201;
  static const getShortArrayRegion = 202;
  static const getIntArrayRegion = 203;
  static const getLongArrayRegion = 204;
  static const getFloatArrayRegion = 205;
  static const getDoubleArrayRegion = 206;
  static const setBooleanArrayRegion = 207;
  static const setByteArrayRegion = 208;
  static const setCharArrayRegion = 209;
  static const setShortArrayRegion = 210;
  static const setIntArrayRegion = 211;
  static const setLongArrayRegion = 212;
  static const setFloatArrayRegion = 213;
  static const setDoubleArrayRegion = 214;

  static const registerNatives = 215;
  static const unregisterNatives = 216;
  static const monitorEnter = 217;
  static const monitorExit = 218;
  static const getJavaVm = 219;
  static const exceptionCheck = 228;
  static const getObjectRefType = 232;
}

/// Slots in `struct JNIInvokeInterface_`, reached through `JavaVM*`.
abstract final class JniVmFn {
  static const destroyJavaVm = 3;
  static const attachCurrentThread = 4;
  static const detachCurrentThread = 5;
  static const getEnv = 6;
  static const attachCurrentThreadAsDaemon = 7;
}

/// `JNI_VERSION_1_6` from jni.h — the lowest version that supports everything
/// bound here, so [JniVersion.v1_6] is what [JniVmFn.getEnv] asks for.
abstract final class JniVersion {
  static const v1_6 = 0x00010006;
  static const v1_8 = 0x00010008;
  static const v9 = 0x00090000;
  static const v10 = 0x000a0000;
  static const v19 = 0x00130000;
  static const v20 = 0x00140000;
  static const v21 = 0x00150000;
}

/// Return codes from `JNI_CreateJavaVM`, `GetEnv` and friends.
abstract final class JniResult {
  static const ok = 0;
  static const err = -1;
  static const detached = -2;
  static const version = -3;
  static const noMemory = -4;
  static const exists = -5;
  static const invalidArguments = -6;

  /// A human-readable name for [code], for error messages.
  static String describe(int code) {
    switch (code) {
      case ok:
        return 'JNI_OK';
      case err:
        return 'JNI_ERR';
      case detached:
        return 'JNI_EDETACHED';
      case version:
        return 'JNI_EVERSION';
      case noMemory:
        return 'JNI_ENOMEM';
      case exists:
        return 'JNI_EEXIST';
      case invalidArguments:
        return 'JNI_EINVAL';
      default:
        return 'unknown code $code';
    }
  }
}
