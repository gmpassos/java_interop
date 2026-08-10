/// Call Java from pure Dart over JNI, using only `dart:ffi`.
///
/// Boots a JVM in-process (or attaches to the one this process already has),
/// loads jars from a class path, and calls constructors, methods, fields and
/// arrays with full primitive coverage. Java throwables surface as Dart
/// [JavaException]s.
///
/// ```dart
/// final jvm = Jvm.startOrAttach(classPath: ['path/to/your.jar']);
///
/// final greeter = JavaClass.forName(jvm, 'com.nfeflash.example.Greeter');
/// final instance = greeter.newInstance('(Ljava/lang/String;)V', ['Dart']);
///
/// print(instance.call('greet', '()Ljava/lang/String;')); // Hello, Dart!
/// print(greeter.callStatic('add', '(II)I', [2, 40]));    // 42
///
/// instance.release();
/// greeter.release();
/// ```
///
/// There are two layers. [JavaClass] / [JavaObject] / [JavaArray] read the
/// signature string and dispatch, convert Dart arguments — a `String` to a
/// `jstring`, a `List` to a Java array, a number to its wrapper — and release
/// the temporaries that makes; they also cache the member ids they resolve.
/// Use these.
/// Underneath, extensions on [Jvm] ([JvmClasses], [JvmCalls], [JvmFields],
/// [JvmArrays], [JvmStrings]) mirror the JNI C API one-to-one for the cases the
/// high-level layer does not cover, and [Jvm.fnSlot] is the escape hatch for
/// JNI functions this binding does not wrap at all.
///
/// > **One JVM per process.** `JNI_CreateJavaVM` may be called once, and
/// > HotSpot cannot start another after [Jvm.destroy]. [Jvm.startOrAttach]
/// > therefore reuses an existing VM when it finds one — which is what makes
/// > this work under `dart test`, where every suite is a separate isolate in a
/// > shared process.
library;

export 'src/boxing.dart' show JavaWrapper, JvmBoxing;
export 'src/errors.dart';
export 'src/java_array.dart' show JavaArray;
export 'src/java_class.dart' show JavaClass, JavaObject;
export 'src/java_home.dart'
    show defaultLibjvmPath, searchLibjvm, libjvmUnder, LibjvmSearch;
export 'src/java_ref.dart' show JavaRef, JavaRefKind, JvmLocalFrames;
export 'src/java_signature.dart'
    show JType, JSig, JavaMethod, JavaField, jsig, jtype;
export 'src/jni_slots.dart' show JniFn, JniVmFn, JniVersion, JniResult;
export 'src/jvalue.dart' show JValue, floatFromBits, doubleFromBits;
export 'src/jvm.dart' show Jvm, classPathSeparator;
export 'src/jvm_arrays.dart' show JvmArrays;
export 'src/jvm_calls.dart' show JvmCalls;
export 'src/jvm_classes.dart' show JvmClasses;
export 'src/jvm_fields.dart' show JvmFields;
export 'src/jvm_strings.dart' show JvmStrings;
export 'src/signatures.dart' show JniSignature, JniType;
