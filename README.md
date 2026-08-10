# java_interop

[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Pure Dart](https://img.shields.io/badge/pure-Dart-00b9fc?logo=dart&logoColor=white)](https://dart.dev)
[![No Flutter](https://img.shields.io/badge/Flutter-not%20required-success?logo=flutter&logoColor=white)](https://dart.dev)
[![License](https://img.shields.io/badge/license-Apache%202.0-green?logo=open-source-initiative&logoColor=green)](https://www.apache.org/licenses/LICENSE-2.0.txt)

**Call Java from pure Dart, over JNI, with nothing but `dart:ffi`.**

Boots a JVM inside your Dart process (or attaches to the one already running),
loads jars from a class path, and calls constructors, methods, fields and arrays
across the full JNI type surface. Java throwables arrive as Dart exceptions
carrying the class name, message and Java stack trace.

```
$ ./run.sh
Hello, Dart! (from Java 21.0.12)
Greeter.add(2, 40) = 42
Greeter.divide(1, 0) threw: JavaException: java.lang.ArithmeticException: / by zero
```

> ## ⚠️ One JVM per process
>
> `JNI_CreateJavaVM` may be called **once** per process, and HotSpot cannot
> start another after `Jvm.destroy()`. `Jvm.startOrAttach` therefore reuses an
> existing VM when it finds one, which is what makes this work under
> `dart test` — every suite is a separate isolate inside one shared process.
> A consequence: **the class path is fixed by whoever creates the VM first**;
> JNI offers no way to extend it later.

## Why not `package:jni`?

Every published version of `package:jni` — 0.1.1 through 1.0.3 — declares a
Flutter requirement:

```yaml
environment:
  sdk: '>=3.3.0 <4.0.0'
  flutter: '>=3.35.6'
```

`dart pub add jni` therefore fails outright on a Flutter-free SDK with *"jni
requires the Flutter SDK"*, even though nothing about loading a jar needs
Flutter. The neighbouring packages do not fill the gap either: `jnigen` has a
Dart-only environment but only *generates* bindings that `import
'package:jni/jni.dart'`; `jni_util` is a path helper with no JNI in it; and
`apollovm` interprets a subset of Java *source* and cannot load a compiled jar.

So this package binds the JNI Invocation API directly with `dart:ffi` — the same
C API `package:jni` wraps. The only dependency is `package:ffi`, which is pure
Dart (it supplies the native allocator and UTF-8 helpers that `dart:ffi` itself
does not expose).

## Features

- **Boot or attach.** `Jvm.startOrAttach` creates a JVM, or finds the one this
  process already has via `JNI_GetCreatedJavaVMs`. Multiple isolates share one
  VM safely, including when several of them start at the same instant.
- **Thread-correct by construction.** `JNIEnv*` is thread-affine and a Dart
  isolate is *not* pinned to an OS thread — it can resume on a different one
  after an `await`. Every call re-resolves the env through `GetEnv`, attaching
  the current thread when needed, so a cached pointer can never go stale.
- **Complete call surface.** Constructors, instance methods and static methods
  for all ten JNI return types (`void`, the eight primitives, references).
- **Fields.** Instance and static, read and written, for every type.
- **Signature-driven dispatch.** `JavaClass` / `JavaObject` parse the descriptor
  and pick the right JNI accessor for you — calling `CallIntMethod` on a method
  that returns `long` is undefined behaviour in raw JNI, not an error.
- **Correct strings.** The UTF-16 (`jchar`) family, so emoji, CJK and embedded
  NULs survive a round trip. JNI's "UTF-8" is *modified* UTF-8 and does not.
- **Arrays.** Creation, length, and bulk region read/write for all eight
  primitive types, plus object arrays including null elements.
- **Explicit reference ownership.** Local and global references, `toGlobal`,
  `isSameObject`, scoped `localFrame`, and a clear Dart error on use-after-
  release instead of handing the VM a dangling pointer.
- **Exceptions both ways.** Java throwables become `JavaException` (class name,
  message, Java stack trace), always cleared before returning so the next call
  is not poisoned; `throwJava` raises one from Dart.
- **An escape hatch.** `Jvm.fnSlot(index)` reaches any JNI function this binding
  does not wrap.
- **Tested.** 242 tests across unit and integration suites, covering every
  primitive type, both directions of every conversion, the reference lifecycle,
  the exception paths, and the multi-isolate startup race.

## Architecture

```
        Your Dart code
              │
     JavaClass / JavaObject      ← signature-driven, converts + releases
              │
   extensions on Jvm (JvmCalls, JvmFields, JvmArrays, JvmStrings, JvmClasses)
              │                    ← 1:1 with the JNI C API
        Jvm.fnSlot(i)             ← escape hatch: any unwrapped JNI function
              │
      JNIEnv* function table      ← resolved per call via GetEnv
              │
     libjvm (JNI Invocation API)
              │
           HotSpot
```

```
lib/
├── java_interop.dart         # public library (exports)
└── src/
    ├── jvm.dart              # lifecycle, per-call env resolution, exceptions
    ├── jni_slots.dart        # function-table indices, read out of jni.h
    ├── native_types.dart     # dart:ffi typedefs and structs
    ├── jvm_classes.dart      # class / method / field resolution
    ├── jvm_calls.dart        # constructors + calls, every return type
    ├── jvm_fields.dart       # instance and static field access
    ├── jvm_strings.dart      # UTF-16 string conversion
    ├── jvm_arrays.dart       # primitive and object arrays
    ├── java_ref.dart         # owned references, local frames
    ├── java_class.dart       # JavaClass / JavaObject ergonomic layer
    ├── signatures.dart       # JniType + JniSignature parse/build
    ├── jvalue.dart           # the 8-byte jvalue union
    ├── java_home.dart        # libjvm discovery
    └── errors.dart           # JniError, JniLookupError, JavaException
```

## Getting started

You need a JDK — a JRE is not enough, since `libjvm` ships with the JDK.

```sh
brew install openjdk@21
```

That formula is keg-only, so `/usr/libexec/java_home` will not find it unless
you symlink it. `java_home.sh` checks the Homebrew prefixes first, which is why
the scripts below work with no shell setup:

```sh
./build.sh   # javac + jar  -> build/java_interop.jar
./run.sh     # builds if needed, then runs the example
./test.sh    # builds if needed, then runs the test suite
```

To run `dart` directly, export `JAVA_HOME` yourself:

```sh
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
dart run example/main.dart
```

## Usage

### Call a class from a jar

```dart
import 'package:java_interop/java_interop.dart';

final jvm = Jvm.startOrAttach(classPath: ['build/java_interop.jar']);

final greeter = JavaClass.forName(jvm, 'com.nfeflash.example.Greeter');
final instance = greeter.newInstance('(Ljava/lang/String;)V', ['Dart']);

print(instance.call('greet', '()Ljava/lang/String;')); // Hello, Dart! ...
print(greeter.callStatic('add', '(II)I', [2, 40]));    // 42

instance.release();
greeter.release();
```

Class names take either form — `java.lang.String` or `java/lang/String` — and
nested classes keep their `$`: `com.example.Outer$Inner`.

### Call the JDK

```dart
final math = JavaClass.forName(jvm, 'java.lang.Math');
math.callStatic('abs', '(I)I', [-5]);        // 5     (int)
math.callStatic('abs', '(D)D', [-5.5]);      // 5.5   (double)
math.getStaticField('PI', JniType.double_);  // 3.14159...

final list = JavaClass.forName(jvm, 'java.util.ArrayList');
final instance = list.newInstance();
instance.call('add', '(Ljava/lang/Object;)Z', ['first']);
instance.javaToString();                     // [first]
```

`Math.abs` is overloaded for `int`, `long`, `float` and `double`. The signature
you pass selects both the Java overload *and* the JNI accessor used to read the
result, so `(I)I` returns a Dart `int` and `(D)D` a Dart `double`.

### Results and arguments

| Java | Dart argument | Dart result |
| --- | --- | --- |
| `boolean` | `bool` | `bool` |
| `byte` `char` `short` `int` `long` | `int` | `int` |
| `float` `double` | `double` (or `int`) | `double` |
| `void` | — | `null` |
| `java.lang.String` | `String` or `null` | `String?` |
| any other reference | `JavaObject`, `JavaRef`, or `null` | `JavaObject` |

A Dart `String` argument is converted to a `java.lang.String` and released
afterwards, even if the call throws. A `String` *return* is converted and its
reference released for you. Every other reference result is a `JavaObject` you
own and must `release()`.

Use `callAs<T>` / `callStaticAs<T>` when you want the cast done for you:

```dart
final sum = fixtures.callStaticAs<int>('staticSum', '(II)I', [2, 40]);
```

### Fields

```dart
object.getField('intField', JniType.int_);              // read
object.setField('stringField', JniType.string, 'text'); // write (auto-converted)

fixtures.getStaticField('staticIntField', JniType.int_);
fixtures.setStaticField('staticStringField', JniType.string, 'x');
```

### Arrays

```dart
// Read one Java produced.
final fromJava = fixtures.callStatic('intArray', '()[I') as JavaObject;
jvm.getIntArray(fromJava.ref);           // [-2147483648, 0, 2147483647]
fromJava.release();

// Build one in Dart and pass it back.
final ints = jvm.newIntArray(4);
jvm.setIntArray(ints, [1, 2, 3, 4]);
fixtures.callStatic('sumInts', '([I)I', [ints]);  // 10
ints.release();

// Object arrays.
final strings = jvm.newObjectArray(3, stringClass);
jvm.setObjectArrayElement(strings, 0, jvm.newString('a'));
```

Reads accept a `start`/`length` window, and an out-of-range one is rejected in
Dart with the array's real length in the message rather than reaching the VM.

### Exceptions

```dart
try {
  fixtures.callStatic('divide', '(II)I', [1, 0]);
} on JavaException catch (e) {
  e.className;      // java.lang.ArithmeticException
  e.message;        // / by zero
  e.isA('ArithmeticException');  // true — matches simple or qualified names
  e.stackTraceText; // the Java stack trace
}

// The VM is immediately usable again.
jvm.throwJava('java.lang.IllegalStateException', 'from Dart');
```

### References and frames

```dart
// Scoped: everything created inside is freed on the way out.
final total = jvm.localFrame(() {
  var length = 0;
  for (var i = 0; i < 1000; i++) {
    length += jvm.stringLength(jvm.newString('value $i'));
  }
  return length;
});

// A global reference survives the frame — and the thread.
late JavaRef kept;
jvm.localFrame(() => kept = jvm.newString('kept').toGlobal());
jvm.stringFrom(kept);
kept.release();
```

### Dropping to raw JNI

The extensions on `Jvm` mirror the C API one-to-one when you want the control:

```dart
final clazz = jvm.findClass('com.nfeflash.example.Fixtures');
final method = jvm.staticMethodId(clazz, 'staticSum', '(II)I');
jvm.callStaticIntMethod(clazz, method, [JValue.fromInt(20), JValue.fromInt(22)]);
```

And for a JNI function this binding does not wrap at all, `fnSlot` gives you the
raw function pointer to cast and call yourself.

## How it works

### The function tables

`JNIEnv*` and `JavaVM*` are each a pointer to a pointer to a table of function
pointers. There are no exported symbols to look up — apart from
`JNI_CreateJavaVM` and `JNI_GetCreatedJavaVMs` — so every call means
dereferencing to the table, indexing the right slot, and casting that slot to
the right signature:

```dart
Pointer<Void> fnSlot(int index) =>
    env.cast<Pointer<Pointer<Void>>>().value[index];

final fn = Jvm.fnSlotOf(env, JniFn.findClass)
    .cast<NativeFunction<FindClassC>>()
    .asFunction<FindClassDart>();
```

The indices in `JniFn` were extracted from `$JAVA_HOME/include/jni.h` of
OpenJDK 21 by numbering the members of `struct JNINativeInterface_` (235 slots,
including the four leading `reserved` entries), not transcribed by hand. The
table is append-only across JNI versions, so they hold for any JNI ≥ 1.6 VM.

### Only the `…A` call variants

The bare `CallObjectMethod` family is C variadic, and arm64 (macOS and Linux)
passes variadic arguments under a different calling convention than fixed ones —
calling them through a non-variadic FFI signature would silently corrupt
arguments. The `A` variants take a `jvalue*` array instead and are correct
everywhere.

### The `jvalue` union

`jvalue` is an 8-byte union, and the `A` variants read whichever member the
*declared* parameter type names. On a little-endian 64-bit target every integral
and reference member lives in the low bytes, so they can all be staged through
an `int`. Floats are the exception: `jfloat` is a 4-byte IEEE-754 value, so its
*bit pattern* has to land in the low 4 bytes — which is why coercing a Dart
`double` needs the signature to know whether it is a `jfloat` or a `jdouble`.

### Threads and `JNIEnv*`

A `JNIEnv*` belongs to one thread. A Dart isolate is *not* pinned to an OS
thread — it can resume on a different one after an `await` — so this binding
never caches it. `Jvm.env` calls `GetEnv` on every access (a thread-local read
in the VM) and falls back to `AttachCurrentThread` when the thread is new.

### The startup race

HotSpot rejects a second `JNI_CreateJavaVM` with `JNI_EEXIST` as soon as the
first one *starts*, but only publishes the VM to `JNI_GetCreatedJavaVMs` once it
has finished booting. A thread that loses the race therefore sees neither a
usable VM nor a creatable one. `startOrAttach` waits for the winner to finish
instead of failing.

This is not hypothetical: `dart test` runs suites concurrently as isolates of
one process, and without this the suite fails intermittently. There is a
regression test (`test/integration/startup_race_test.dart`) that runs the race
in a fresh process, since it cannot recur once any VM exists.

### Strings

`NewStringUTF` / `GetStringUTFChars` speak *modified* UTF-8: U+0000 is encoded
as two bytes, and characters outside the BMP as a surrogate pair of three bytes
each. A Dart string containing an emoji or a NUL does not survive that round
trip. Dart strings are already UTF-16, so this binding uses `NewString` /
`GetStringChars` (the `jchar` family), which is both exact and cheaper.

## Limitations

- **One JVM per process**, fixed class path, no restart after `destroy()`.
  These are HotSpot limitations, not limitations of this binding.
- **No `GetArrayElements`.** Only the region-copy API is bound. The elements
  family may hand back a direct pointer into the Java heap and pin it, which is
  easy to leak and blocks the GC while held.
- **No reflection helpers, no weak references, no `RegisterNatives`.** Calling
  Dart *from* Java is out of scope.
- **No custom class loaders.** Classes come from the class path the VM was
  created with.
- **`JavaObject` does not auto-release.** Ownership is explicit; use
  `release()` or `localFrame`. There is no finalizer, because a `JNIEnv*` is
  thread-affine and a Dart finalizer offers no guarantee about which thread it
  runs on.

## Running the example and tests

```sh
./build.sh                      # compile the Java fixtures into build/java_interop.jar
./run.sh                        # the small greeter example
dart run example/main.dart      # a tour of the whole feature set
./test.sh                       # the full suite (builds the jar first)
dart test test/unit             # unit tests only — no JVM needed
```

The suite skips itself with an explanation when no JDK is installed, rather than
failing with a native error from inside `DynamicLibrary.open`.

## Source

Part of the [`nfeflash_nfe_generator`](../../) package, under `example/`.

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
