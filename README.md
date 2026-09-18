# java_interop

[![pub package](https://img.shields.io/pub/v/java_interop.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/java_interop)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Pure Dart](https://img.shields.io/badge/pure-Dart-00b9fc?logo=dart&logoColor=white)](https://dart.dev)
[![No Flutter](https://img.shields.io/badge/Flutter-not%20required-success?logo=flutter&logoColor=white)](https://dart.dev)
[![Dart CI](https://github.com/gmpassos/java_interop/actions/workflows/dart.yml/badge.svg?branch=main)](https://github.com/gmpassos/java_interop/actions/workflows/dart.yml)
[![codecov](https://codecov.io/gh/gmpassos/java_interop/branch/main/graph/badge.svg)](https://codecov.io/gh/gmpassos/java_interop)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/java_interop?logo=git&logoColor=white)](https://github.com/gmpassos/java_interop/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/java_interop/latest?logo=git&logoColor=white)](https://github.com/gmpassos/java_interop/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/java_interop?logo=git&logoColor=white)](https://github.com/gmpassos/java_interop/commits/main)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/java_interop?logo=github&logoColor=white)](https://github.com/gmpassos/java_interop/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/java_interop?logo=github&logoColor=white)](https://github.com/gmpassos/java_interop)
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
- **Signatures written as Java.** `callJava('int add(int, int)')` instead of
  `call('add', '(II)I')`. Paste the declaration from the Java source or from
  `javap`: modifiers, parameter names, generics and `throws` are ignored. A
  typed builder (`JSig`, `JType`) covers the cases you want `const` or
  programmatic.
- **Correct strings.** The UTF-16 (`jchar`) family, so emoji, CJK and embedded
  NULs survive a round trip. JNI's "UTF-8" is *modified* UTF-8 and does not.
- **Arrays.** A `JavaArray` that carries its element type: a Dart `List` passes
  as an array argument, an array result reads back as a typed list (`Int32List`,
  `List<String?>`, nested `JavaArray`s), and elements are indexable. Underneath,
  creation, length, and bulk region read/write for all eight primitive types,
  plus object arrays including null elements.
- **Boxing.** A Dart number, `bool` or `String` passed where a wrapper or an
  erased `Object` is declared is boxed into `Integer`/`Long`/`Double`/… and
  released afterwards; a declared wrapper result is unboxed back to an `int`,
  `double` or `bool`. `toDart()` does the same for a value whose declared type
  was only `Object` — which, after erasure, is every generic API.
- **Member ids are cached.** `JavaClass` caches each `jmethodID`/`jfieldID` it
  resolves, and a `JavaObject` holds the runtime class it looked up, so a call
  in a loop pays for `GetMethodID` once instead of once per invocation.
  `jvm.classFor(name)` keeps one instance per class for the process, so the cache
  pays off by default rather than by remembering to hold the class yourself.
- **Explicit reference ownership.** Local and global references, `toGlobal`,
  `isSameObject`, scoped `localFrame`, and a clear Dart error on use-after-
  release instead of handing the VM a dangling pointer.
  `localFrameReturning` covers the case a scope cannot: building one reference
  worth keeping, without the dangling handle that returning from `localFrame`
  silently produces.
- **Exceptions both ways.** Java throwables become `JavaException` (class name,
  message, Java stack trace, and the `getCause()` chain — which is where the
  class that explains the failure usually is, since libraries rewrap), always
  cleared before returning so the next call is not poisoned; `throwJava` raises
  one from Dart.
- **Binary data.** `JavaArray.toBytes()` reads a `byte[]` straight into a
  `Uint8List`, because Java's `byte` is signed and everything in Dart that
  consumes bytes is not.
- **Answers about the environment.** `isAttached` (did this call create the VM,
  or attach to one whose class path you cannot see?), `systemProperty`,
  `resourceExists` / `resourceUrls`, and `requireClasses` — which fails at
  startup naming the class *and* the artifact, instead of leaving a
  `NoClassDefFoundError` to surface from inside a library later.
- **Java interfaces implemented in Dart.** `jvm.implementInterface(...)` returns a
  real Java object: listeners, visitors, `Comparator`, SPI. Reentrant calls (the
  usual kind — Java is only running because Dart called it) are dispatched
  synchronously and return a value; calls from a thread the JVM owns are queued
  when they are `void` and refused with a clear Java exception when they are not,
  so nothing can deadlock.
- **Monitors.** `jvm.synchronized(object, body)` takes the same lock Java's
  `synchronized` does, which matters as soon as a Dart callback can mutate state
  Java's other threads read.
- **An escape hatch.** `Jvm.fnSlot(index)` reaches any JNI function this binding
  does not wrap.
- **Tested.** 467 tests across unit and integration suites, covering every
  primitive type, both directions of every conversion, arrays and boxing,
  signature parsing, the reference lifecycle, the exception paths including cause
  chains and cycles, proxies across threads and isolates, and the multi-isolate
  startup race.

## Architecture

```
        Your Dart code
              │
  JavaClass / JavaObject / JavaArray   ← signature-driven, converts + releases
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
you symlink it. The `java_home.sh` each project carries checks the Homebrew
prefixes first, which is why the scripts below work with no shell setup:

```sh
./build.sh   # both jars: the test fixtures and the greeter's own
./run.sh     # builds if needed, then runs the greeter example
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

final jvm = Jvm.startOrAttach(classPath: ['example/greeter/build/greeter.jar']);

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

### Writing signatures as Java, not as descriptors

A descriptor is easy to get subtly wrong, and it fails in the least helpful way:
`J` is `long` and `I` is `int`, `Z` is `boolean`, a class needs `L`, a trailing
`;` and slashes rather than dots — and a mistake surfaces as a
`NoSuchMethodError` from inside the VM. Write the Java declaration instead:

```dart
instance.callJava('String greet()');
fixtures.callJavaStatic('int add(int, int)', [2, 40]);
clazz.newJava('(String, int)', ['demo', 7]);

object.getJavaField('int intField');
object.setJavaField('String stringField', 'text');
```

The declaration is what you would read in the Java source or in `javap` output,
so it can be pasted in unedited — modifiers, annotations, parameter names,
generic arguments and a `throws` clause are all ignored, `java.lang` is implicit,
and varargs count as an array:

```dart
jsig('public static int add(int a, int b)')            // (II)I
jsig('java.util.List<String> subList(int, int)')       // (II)Ljava/util/List;
jsig('void write(byte[]) throws java.io.IOException')  // ([B)V
jsig('String format(String, Object...)')               // (Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;
jtype('int[][]')                                       // [[I
```

`jsig` and `jtype` return the descriptor string, so they drop into the existing
`call` / `callStatic` / `getField` unchanged. For a signature built
programmatically — or one you want `const` — there is a typed builder that
cannot produce a malformed descriptor:

```dart
const add = JSig.of([JType.int_, JType.int_], returns: JType.int_);  // (II)I
JSig.ctor([JType.string]);                                          // (Ljava/lang/String;)V
JType.of('java.util.List');                                         // Ljava/util/List;
JType.int_.array.array;                                             // [[I
```

Both routes produce the same `JSig`. Declarations are parsed once and cached, so
a call in a loop re-parses nothing.

> A malformed declaration is a `JniError` at the call, naming the token that
> failed — not a `NoSuchMethodError` from the VM later. It is still a runtime
> check; the typed builder is the compile-time one.

### Results and arguments

| Java | Dart argument | Dart result |
| --- | --- | --- |
| `boolean` | `bool` | `bool` |
| `byte` `char` `short` `int` `long` | `int` | `int` |
| `float` `double` | `double` (or `int`) | `double` |
| `void` | — | `null` |
| `java.lang.String` | `String` or `null` | `String?` |
| `Integer` `Long` `Double` … | `int` / `double` / `bool` | `int?` / `double?` / `bool?` |
| `Object` `Number` `Comparable` | `int` / `double` / `bool` (boxed, see below) | `JavaObject` |
| any array | `List`, `JavaArray`, or `null` | `JavaArray` |
| any other reference | `JavaObject`, `JavaRef`, or `null` | `JavaObject` |

The rule is that a *declared* type Dart has a direct equivalent for is converted
in both directions, and everything else is a `JavaObject` you own and must
`release()`. Conversions that allocate in the VM — a `jstring` for a `String`, a
box for a number, an array for a `List` — are released for you afterwards, even
if the call throws.

Use `callAs<T>` / `callStaticAs<T>` when you want the cast done for you:

```dart
final sum = fixtures.callStaticAs<int>('staticSum', '(II)I', [2, 40]);
```

### Fields

```dart
object.getJavaField('int intField');                    // read
object.setJavaField('String stringField', 'text');      // write (auto-converted)

fixtures.getJavaStaticField('int staticIntField');
fixtures.setJavaStaticField('String staticStringField', 'x');
```

Or with the descriptor spelled out, which is what the above resolves to:

```dart
object.getField('intField', JniType.int_);
object.setField('stringField', JniType.string, 'text');
```

### Arrays

An array result is a `JavaArray` that carries its element descriptor, so one
type covers all nine element kinds:

```dart
final fromJava = fixtures.callStatic('intArray', '()[I') as JavaArray;
fromJava.toList();   // Int32List [-2147483648, 0, 2147483647]
fromJava[0];         // -2147483648
fromJava.release();

// A String[] reads back as Dart strings, nulls preserved; an Integer[] unboxes.
(fixtures.callStatic('stringArray', '()[Ljava/lang/String;') as JavaArray)
    .toList();       // ['one', null, 'três']
```

A Dart `List` passed for an array parameter is converted and released for you:

```dart
fixtures.callStatic('sumInts', '([I)I', [[1, 2, 3, 4]]);              // 10
fixtures.callStatic('sumNested', '([[I)I', [[[1, 2], [3]]]);          // 6
fixtures.callStatic('joinStrings', sig, [['a', 'b', 'c']]);           // a,b,c
```

Or build one to keep across calls, and mutate it in place:

```dart
final ints = JavaArray.ofInts(jvm, [10, 20, 30]);
ints[0] = 100;
fixtures.callStatic('sumInts', '([I)I', [ints]);  // 150
ints.release();

JavaArray.sized(jvm, JniType.string, 3);          // String[3], null-filled
```

`toList` accepts a `start`/`length` window, and an out-of-range one is rejected
in Dart with the array's real length in the message rather than reaching the VM.
The `JvmArrays` extension underneath is unchanged if you want the raw
`newIntArray` / `getIntArray` / region calls.

### Boxed primitives

Java's autoboxing is a compiler feature, so JNI never does it. This binding
does, driven by the declared descriptor:

```dart
// A declared wrapper is exact in both directions.
fixtures.callStatic('unboxInteger', '(Ljava/lang/Integer;)I', [42]);  // 42
fixtures.callStatic('boxInteger', '(I)Ljava/lang/Integer;', [7]);     // 7 (an int)

// Which makes generic APIs — everything erased to Object — usable directly.
list.call('add', '(Ljava/lang/Object;)Z', [1]);
map.call('put', '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;',
    ['answer', 42]);
```

For an **erased** parameter (`Object`, `Number`, `Comparable`, `Serializable`)
the wrapper has to be inferred, which is the one place this binding guesses what
javac would have known statically: `bool` → `Boolean`, `double` → `Double`, and
`int` → `Integer` when it fits in 32 bits, otherwise `Long`. That split matters
for `equals`, so pass an explicit box when the Java side stores a specific width:

```dart
final long = jvm.boxLong(42);   // ... boxInt, boxDouble, boxChar, boxAs(...)
fixtures.callStatic('classOf', classOfSig, [long]);  // java.lang.Long
long.release();
```

Going the other way, a method *declared* to return `Object` still gives a
`JavaObject` — only the VM knows what is inside it. `toDart()` asks:

```dart
final value = map.call('get', '(Ljava/lang/Object;)Ljava/lang/Object;', ['answer'])
    as JavaObject;
value.toDart();  // 42 — an int, a double, a bool, a String, or the object itself
value.release();
```

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

Read `causes` before deciding what a failure *means*. Libraries rewrap
constantly — `catch (Exception e) { throw new Wrapper(e.getMessage(), e); }` — so
the class that identifies the problem is often not `className` but a link
further down the chain:

```dart
try {
  api.callJava('void send()');
} on JavaException catch (e) {
  e.className;   // com.example.ApiException — the wrapper
  e.causes;      // [java.net.SocketTimeoutException: connect timed out, …]

  if (e.isCausedBy('java.net.SocketTimeoutException')) {
    // Retryable. The same wrapper around a validation failure is not, and only
    // the chain tells the two apart.
  }
  e.causeOf('IOException')?.message;
}
```

### Caller-sensitive JDK APIs

Some JDK methods look at *who called them* — `Reflection.getCallerClass()` — to
pick a class loader, a module, or a resource bundle. Called over JNI there is no
Java frame above them, so the caller comes back `null` and the method fails in a
way that has nothing to do with what you asked for:

```
NullPointerException: Cannot invoke "java.lang.Class.getModule()"
because "caller" is null
```

This is a property of those APIs, not a gap in this binding: the same call from a
`main` works fine. Each has an overload that takes explicitly what it would
otherwise have inferred.

| Instead of | Call |
|---|---|
| `Logger.getLogger(name)` | `LogManager.getLogManager().readConfiguration(stream)` — and it applies to loggers created later, too |
| `Class.forName(name)` | `Class.forName(name, true, loader)`, or `jvm.findClass` |
| `ResourceBundle.getBundle(name)` | `ResourceBundle.getBundle(name, locale, loader)` |
| `DriverManager.getConnection(url)` | a `DataSource` obtained explicitly |
| `MethodHandles.lookup()` | `MethodHandles.privateLookupIn(someClass, …)` |

Configuring `java.util.logging` is the one most projects hit, because a library
that logs at `INFO` will otherwise flood stderr:

```dart
// Not Logger.getLogger(...).setLevel(...) — that throws under JNI.
final manager = jvm.classFor('java.util.logging.LogManager');
final properties = utf8.encode('org.noisy.library.level=WARNING\n');
// ... hand `properties` to readConfiguration via a ByteArrayInputStream ...
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

### Implementing a Java interface in Dart

A library that wants a listener, a visitor or a `Comparator` wants an *object*
implementing an interface. `implementInterface` builds one:

```dart
final ordering = jvm.implementInterface(
  'java.util.Comparator',
  onInvoke: (call) => switch (call.methodName) {
    'compare' => (call.args[0] as int).compareTo(call.args[1] as int),
    _ => null,
  },
);
try {
  jvm.classFor('java.util.Arrays').callJavaStatic(
    'void sort(Object[], java.util.Comparator)',
    [values, ordering.instance],
  );
} finally {
  ordering.release();
}
```

Arguments arrive as Dart values — `null`, `bool`, `int`, `double`, `String`, or a
`JavaObject`. The return value is converted for the method's *declared* type, so
returning `1` from a method declared `byte` is fine: Dart has one integer type and
the narrowing happens on the Java side, where the declared type is known. Several
interfaces at once (`implementInterfaces`), per-method handlers
(`handlers: {'visitStaticText': …}`), and `call.method` for the underlying
`java.lang.reflect.Method` are all there.

`toString`, `equals` and `hashCode` are answered in Java by default — identity
equality, identity hash, a name listing the interfaces — because `Proxy` routes
them to the handler like anything else, and a proxy without them breaks the moment
it reaches a `HashMap` or a log line. Pass `forwardObjectMethods: true` to take
them yourself.

**Which thread calls matters.** A reentrant call — Java calling back during a call
Dart made, which is nearly all of them — runs synchronously on the isolate's own
thread and returns a value. A call from a thread the JVM owns cannot: Dart aborts
the process if an `isolateLocal` callback is entered from another thread, and
blocking that thread until the isolate answers deadlocks as soon as the isolate is
itself inside a JNI call. So a `void` method is *queued* and runs on the next turn
of the event loop (`call.isQueued` is true), and a method with a return value
throws `IllegalStateException` in Java naming both threads. Neither can hang.

An isolate is not pinned to an OS thread, so which thread is "the isolate's" is
re-checked whenever you read `proxy.instance`. If you cache the `JavaObject` and
hand it to Java after an `await` that moved the isolate, call
`proxy.bindCurrentThread()` first — otherwise the call is refused, with a message
saying so.

There is no jar. The one Java class this needs
(`java/dart/jni/DartInvocationHandler.java`) is compiled by
`tool/gen_proxy_class.dart` into checked-in bytes and loaded at runtime with JNI
`DefineClass`, into a class loader created per isolate. That last part is not
cosmetic: `RegisterNatives` binds to a *class*, so a shared class would let the
last isolate to bind steal every other isolate's callbacks — and a callback
entered from the wrong isolate's thread aborts the process.

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

A thread attached that way also gets a **context class loader**. JNI leaves it
null, while the thread that created the VM gets the application loader — so
anything that discovers implementations through it (`ServiceLoader`, JAXB, StAX,
JAXP, or any library calling `getResources` on it) would behave differently
depending on which thread happened to serve the call, and an isolate can resume
on any of them. `Jvm.env` fills a *null* loader with
`ClassLoader.getSystemClassLoader()`, which is the loader built from the class
path you passed; a loader set deliberately on the thread is left alone.

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
- **No weak references.** Global and local only.
- **Overloads are not resolved from argument types.** Every call names its
  descriptor, or a Java declaration that yields one.
- **A proxy cannot answer a JVM-owned thread that wants a value.** `void` methods
  from such threads are queued; anything else is refused. See above for why
  blocking there cannot be made safe.
- **A live proxy keeps its isolate alive**, since a JVM thread may still queue a
  call to it. Release it (or the whole runtime) and the isolate ends normally.
- **Boxing into an erased `Object` is inferred, not known.** A Dart `int` picks
  `Integer` or `Long` by width, which is not always what javac would have
  chosen; box explicitly when the difference is observable.
- **The member-id cache lives on a `JavaClass`.** Two `JavaClass.forName` calls
  for the same class do not share one — use `jvm.classFor(name)`, which keeps a
  single instance per class. An object that resolved its own runtime class holds
  it until released.
- **Some JDK APIs are caller-sensitive** and fail over JNI because there is no
  Java frame to inspect. See the section above for the ones that matter and what
  to call instead.
- **No custom class loaders.** Classes come from the class path the VM was
  created with. (The proxy machinery creates one for itself, to give each
  isolate's handler class a distinct identity, but it loads nothing from it.)
- **`JavaObject` does not auto-release.** Ownership is explicit; use
  `release()` or `localFrame`. There is no finalizer, because a `JNIEnv*` is
  thread-affine and a Dart finalizer offers no guarantee about which thread it
  runs on.

## Running the example and tests

```sh
./build.sh                      # both jars, each beside the sources it comes from
./run.sh                        # the small greeter example (example/greeter/)
dart run example/main.dart      # a tour of the whole feature set — no jar needed
./test.sh                       # the full suite (builds the fixtures first)
dart test test/unit             # unit tests only — no JVM needed
```

Each project builds its own jar from its own Java sources, so nothing is shared
between the suite and the examples:

| Project | Sources | Jar |
| --- | --- | --- |
| test suite | `test/java/` | `test/build/fixtures.jar` |
| greeter example | `example/greeter/java/` | `example/greeter/build/greeter.jar` |

Every example except the greeter needs no jar and no class path, since they call
classes the JVM already has:

```sh
dart run example/main.dart          # the whole API surface, against the JDK
dart run example/jdk_apis.dart      # SHA-256, locale currency, deflate/inflate
dart run example/collections.dart   # ArrayList and HashMap from Dart values
dart run example/performance.dart   # member-id caching and local frames
dart run example/threads.dart       # Java's threads, and which calls they may make
```

[`example/example.md`](example/example.md) indexes all six and says which to
read for a given task. The greeter is
[its own project](example/greeter/) with a path dependency on this one, so it
exercises the package through its public API exactly as a consumer would.

The suite skips itself with an explanation when no JDK is installed, rather than
failing with a native error from inside `DynamicLibrary.open`.

## Source

[github.com/gmpassos/java_interop](https://github.com/gmpassos/java_interop) —
issues and pull requests welcome.

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
