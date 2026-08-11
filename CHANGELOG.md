# Changelog

## 1.4.0

Java interfaces can be implemented in Dart. This was the one capability gap: a
library that wants a listener, a visitor, a `Comparator` or an SPI wants an
*object*, and JNI has no way to make one — `Proxy.newProxyInstance` needs an
`InvocationHandler` and `RegisterNatives` needs a class, and both are Java.

Still additive; nothing existing changes.

### `jvm.implementInterface` / `implementInterfaces`

```dart
final ordering = jvm.implementInterface(
  'java.util.Comparator',
  onInvoke: (call) => switch (call.methodName) {
    'compare' => (call.args[0] as int).compareTo(call.args[1] as int),
    _ => null,
  },
);
try {
  arrays.callJavaStatic('void sort(Object[], java.util.Comparator)', [
    values,
    ordering.instance,
  ]);
} finally {
  ordering.release();
}
```

Arguments arrive as Dart values, with boxed primitives unboxed — `Proxy` hands
everything over as `Object`, and an `Integer` is rarely what a handler wants.
Return values are narrowed to the method's *declared* type on the Java side: Dart
has one integer type and cannot know whether `1` means a `byte` or a `long`, and
`Proxy` reports the wrong wrapper as a `ClassCastException` naming neither the
method nor the value.

`toString`, `equals` and `hashCode` are answered in Java by default. `Proxy`
routes them to the handler like any other method, and a proxy without them breaks
the first time it reaches a `HashMap` or a log line, for reasons that look nothing
like the cause. `forwardObjectMethods: true` takes them anyway.

Also: `handlers` keyed by method name, `call.method` for the underlying
`java.lang.reflect.Method`, `call.descriptor`, Dart errors surfacing as Java
exceptions (a `JavaException` keeps its original class, so an upstream `catch`
still matches), `liveProxyCount`, `queuedProxyCalls`, `droppedProxyCalls` and
`releaseProxyRuntime`.

One case has no good answer and so is counted rather than raised: a proxy Dart
has released, called from a thread the JVM owns. Java queues the call and
returns; by the time Dart looks there is no handler to run it *and* no
`onQueuedError` to tell, because both went with the proxy. Throwing there would
end the isolate over something the caller could not prevent, so the call is
dropped and `droppedProxyCalls` counts it — a non-zero count means some Java code
outlived its proxy.

### Threads, which is the part that is actually hard

A reentrant call — Java calling back during a call Dart made, which covers
visitors, comparators, `forEach` and every single-abstract-method interface — runs
synchronously on the isolate's own thread and returns a value.

A call from a thread the JVM owns cannot. Two facts make that impossible rather
than merely awkward, and both were verified rather than assumed:

- A Dart `isolateLocal` callback entered from another thread **aborts the
  process** — "Cannot invoke native callback outside an isolate" — *before* any
  Dart code runs. Dart cannot defend itself, so the thread check lives in Java,
  where `Thread.currentThread()` is free and reliable.
- A `listener` callback is safe from any thread, but runs after the calling frame
  is gone, and by then every `jobject` in its arguments is dead.

So a `void` method called from a JVM thread is *queued*: Java parks the arguments
where they stay reachable, hands Dart a numeric id, and returns; Dart runs the
handler on the next turn of its event loop with `call.isQueued` set. A method with
a return value throws `IllegalStateException` in Java, naming both threads.
Nothing deadlocks, and nothing silently does nothing.

Which thread is "the isolate's" is not fixed: awaiting an `Isolate.run` is enough
to resume the main isolate on the thread the child just freed. Reading
`proxy.instance` re-checks it — through the `JNIEnv*`, which is per-thread and so a
free identity token — and `proxy.bindCurrentThread()` is the escape hatch for an
instance cached across an `await`. The check only ever narrows: Java's `Thread`
comparison decides, so it can refuse a call that would have worked, never accept
one that aborts.

A live proxy keeps its isolate alive, because a JVM thread may still queue a call
to it. Releasing it lets the isolate end — so `release()` stays the only thing to
remember, rather than that *and* tearing down machinery you never asked to build.

`example/threads.dart` runs all of it against the JDK, with no jar: a
`parallelSort` across every core, a Dart `Runnable` on a `java.lang.Thread` and
in a fixed pool — four workers, four queued calls, one handler at a time — a
`Callable` refused with both threads named, `jvm.synchronized` around a
check-then-act on a synchronized list, and a `CountDownLatch` waited on in
slices, because the countDown it is waiting for happens in a handler only the
event loop can run.

### No jar

`java/dart/jni/DartInvocationHandler.java` is compiled by
`tool/gen_proxy_class.dart` into `lib/src/proxy_class.g.dart` as bytes, and loaded
at runtime with JNI `DefineClass`. The Java source stays readable in the
repository, the bytes travel as Dart source, and no consumer needs a JDK. Each
isolate defines it into a class loader of its own: `RegisterNatives` binds to a
*class*, so one shared class would let the last isolate to bind steal every other
isolate's callbacks — and a callback entered from the wrong isolate's thread aborts
the process.

### Monitors and reference types

- `jvm.synchronized(object, body)` takes the same lock Java's `synchronized`
  does, which matters now that a Dart callback can mutate state other Java threads
  read. Reentrant, released on the way out even when the body throws, and
  synchronous by signature: a monitor belongs to the OS thread that entered it, so
  awaiting inside one would leave it held by a thread that has moved on.
- `jvm.refTypeOf(ref)` reports what the *VM* thinks a handle is
  (`GetObjectRefType`) — the way to catch this library's bookkeeping disagreeing
  with reality.

### Tests

467, up from 366 in 1.2.0. The ones worth naming, because they cover failures
that abort the process instead of throwing — a regression there shows up as a
dead test runner, not a red test:

- a `Comparator` implemented in Dart driving the JDK's own `Arrays.sort`, and
  20,000 invocations through one proxy without exhausting the local reference
  table;
- four isolates each building their own handler class in one VM, then the first
  isolate still working after the others exit — run as a separate process,
  because sharing a binding aborts rather than fails;
- a proxy still answering after `await Isolate.run` moved the isolate to another
  OS thread;
- a value demanded from a JVM-owned thread being refused with both threads named,
  rather than deadlocking;
- `Jvm.isAttached` proven in both states, which needs a process where the order of
  creation is controlled: inside the suite, whether this isolate won the race to
  create the VM is not knowable.

## 1.3.0

Everything here came out of porting a real Java library to Dart — a Brazilian
electronic-invoice stack: XML signing, SOAP over mutual TLS, JasperReports. About
530 lines of that port turned out to be things any consumer would have had to
write, plus two rough edges that cost real debugging time.

All additive.

### Cause chains

`JavaException.causes` walks `getCause()`, outermost first, with
`isCausedBy(name)` and `causeOf(name)`.

This matters more than it sounds. Libraries rewrap relentlessly —
`catch (Exception e) { throw new Wrapper(e.getMessage(), e); }` — so the class
that says what actually went wrong is usually not the one thrown. A connection
timeout arriving as a library-specific exception is retryable; the same wrapper
around a validation failure is not, and only the chain tells them apart. The
alternative was scraping `Caused by:` lines out of `stackTraceText` with a regex.

The walk is bounded and detects cycles: `initCause` forbids a self-cause, but a
subclass overriding `getCause()` can still build one.

### Unsigned bytes

`JavaArray.toBytes()` reads a `byte[]` into a `Uint8List`;
`getUnsignedByteArray` is the primitive underneath.

Java's `byte` is signed, so `toList()` gives an `Int8List` — correct, and the
wrong type for every Dart API that consumes bytes. Converting afterwards with
`map((b) => b & 0xff)` allocates per element and yields an untyped `List<int>`;
reading the region into the right buffer costs the one copy JNI needs anyway.

### Answers about the environment

- `Jvm.isAttached` / `Jvm.created` — did this call create the VM, or attach to
  one someone else made? Previously the only signal was an empty `classPath`,
  which is also what a VM created *with* an empty class path looks like. The
  difference matters because JNI cannot extend a running VM's class path: if
  something else booted the VM first, the classes you asked for are not there,
  and learning that at startup beats a `NoClassDefFoundError` an hour later.
- `Jvm.systemProperty(key)`.
- `Jvm.resourceExists(path)` / `resourceUrls(path)` — a merged jar that dropped a
  `META-INF/services` entry looks fine until the one code path needing it runs.
- `Jvm.requireClasses({class: artifact})` — fails naming both.

### Frames that return a value

`localFrameReturning` and `localFrameReturningObject`.

Returning a `JavaRef` from `localFrame` compiles, runs, and hands back a
**dangling handle** — the frame freed it on the way out, nothing reports it, and
the next use is undefined behaviour somewhere unrelated. `PopLocalFrame` has
always accepted a result reference and promoted it into the enclosing frame; this
exposes that.

### A class registry

`jvm.classFor(name)` keeps one `JavaClass` per class, per VM.

The member-id cache lives on the instance, so resolving the same class twice
quietly discards every method and field id already looked up. The cache used to
pay off only if you held the class yourself; now it pays off by default.
`isClassCached`, `cachedClassCount` and `releaseCachedClasses` round it out.

`JavaClass.enumConstant(name)` reads an enum constant as a global reference —
finitely many, never changing, passed constantly, and exactly the wrong thing to
re-read or to hold past a frame.

### Better failures

- `newJava` now accepts the declaration written the way Java source writes it:
  `newJava('ByteArrayInputStream(byte[])')` works, as does the qualified form. It
  used to parse as a *method* returning that class and fail with
  `no such method: <init>([B)Ljava/io/ByteArrayInputStream;` — pointing at the
  constructor rather than at the declaration. A return type that is not this class
  is rejected, with the form to use instead.
- The README documents **caller-sensitive JDK APIs** — `Logger.getLogger`,
  `Class.forName(String)`, `ResourceBundle.getBundle`,
  `DriverManager.getConnection`, `MethodHandles.lookup` — which throw
  `NullPointerException: Cannot invoke "java.lang.Class.getModule()" because
  "caller" is null` over JNI, because `Reflection.getCallerClass()` has no Java
  frame to find. Each has an overload taking explicitly what it would otherwise
  infer.

## 1.2.0

Signatures written as Java, so a descriptor never has to be typed by hand.

A descriptor fails in the least helpful way there is: `J` is `long` and `I` is
`int`, `Z` is `boolean`, a class needs `L`, a trailing `;` and slashes instead of
dots — and getting any of it wrong surfaces as a `NoSuchMethodError` from inside
the VM, pointing at nothing.

### Declarations

- `JavaObject.callJava`, `JavaClass.callJavaStatic` and `JavaClass.newJava` take
  one Java declaration carrying both the name and the types, so neither is
  written twice:

  ```dart
  instance.callJava('String greet()');
  fixtures.callJavaStatic('int add(int, int)', [2, 40]);
  clazz.newJava('(String, int)', ['demo', 7]);
  ```

- `getJavaField` / `setJavaField` and their static counterparts do the same for
  fields: `object.getJavaField('int intField')`.
- `callJavaAs<T>` and `callJavaStaticAs<T>` for the typed variants.
- The declaration is what `javap` prints, so it can be pasted in unedited:
  modifiers, annotations, parameter names, generic arguments and a `throws`
  clause are ignored, `java.lang` is implicit, and varargs count as an array.
- `jsig('int add(int, int)')` and `jtype('int[][]')` return the descriptor
  string for use with the existing `call` / `callStatic` / `getField`.

### Typed builder

- `JType` and `JSig` build a descriptor that cannot be malformed, and are
  `const`-constructible for a signature on a hot path:

  ```dart
  const add = JSig.of([JType.int_, JType.int_], returns: JType.int_);
  JType.of('java.util.List');
  JType.int_.array.array;   // [[I
  ```

- `JavaMethod.parse` and `JavaField.parse` expose the parsed form when the name
  and the signature are wanted separately. Both cache by declaration string, so
  a call in a loop re-parses nothing.

### Notes

- Nothing is deprecated: every existing `String signature` API works unchanged,
  and the new spellings resolve to exactly the same descriptors.
- A malformed declaration raises a `JniError` at the call site naming the token
  that failed. That is still a runtime check — the typed builder is the
  compile-time one.

## 1.1.1

First release on pub.dev. Repository, examples and CI — **no library changes**:
the only edit under `lib/` is a corrected doc comment, so upgrading from 1.1.0
changes nothing at runtime.

### Compatibility

- The SDK floor drops from `^3.12.2` to `^3.10.0`. Nothing in the package needed
  3.12, and CI now runs `dart analyze` and the full suite on a pinned 3.10.0 SDK
  as well as on stable, so the floor is exercised rather than asserted.

### Examples

- Three task-oriented examples, none of which needs a jar or a class path:
  `jdk_apis.dart` (SHA-256 through `MessageDigest`, locale-aware currency
  through `NumberFormat` and `Locale`, a deflate/inflate round trip using a Java
  array as a buffer Java writes into), `collections.dart` (`ArrayList` and
  `HashMap` driven with plain Dart values, ending in reusable `dartListFrom` and
  `dartMapFrom` converters), and `performance.dart` (holding a `JavaClass` for
  its member-id cache, and scoping references with `localFrame`, with timings).
- `example/example.md` indexes all five, says which needs a jar, and points at
  the right one for a given task.
- The tour in `example/main.dart` is rewritten against the JDK, so it needs no
  jar either. `String.valueOf`'s per-primitive overloads make a better
  demonstration than the old fixtures did: the descriptor alone picks the
  overload, and the text that comes back proves the value landed in the right
  bytes of its `jvalue` slot. `Arrays.sort` shows an array Java mutates in
  place, which the previous example could not.
- The greeter moved to `example/greeter/`, a standalone project with a path
  dependency on this package — so it consumes the public API the way a real
  consumer does, and a gap in the exports fails there first.

### Project layout

- The test suite and the greeter example each own everything they build and run
  from: `test/java/` → `test/build/fixtures.jar` via `test/build.sh`, and
  `example/greeter/java/` → `example/greeter/build/greeter.jar` via its own
  `build.sh`, with a `java_home.sh` apiece. Previously they shared one `java/`
  directory and one jar, so each compiled and loaded the other's classes.
- Root `build.sh` delegates to both. `test.sh` and `run.sh` use the one
  belonging to what they run.
- Two tests that used the greeter's class moved to the fixtures, for shapes the
  fixtures already had.

### Repository

- Apache 2.0 `LICENSE`.
- GitHub Actions CI: format, analyze (`--fatal-infos --fatal-warnings`) and
  `dart doc` on Linux; the full suite and every example on Linux **and** macOS,
  since locating and loading `libjvm` is the per-platform part of this package.
- Coverage collected on both platforms and uploaded to Codecov, gated on the
  token being present so a fork or a clone without it still builds green.
- Badges for CI, coverage, last commit, open pull requests and code size.

### Fixed

- The package's own usage snippet told readers to load `build/fixtures.jar`, a
  filename that never existed anywhere in the repository.

## 1.1.0

Arrays, boxed primitives and member-id caching at the ergonomic layer. The three
gaps that forced a drop to raw JNI for ordinary Java code.

### Arrays

- `JavaArray`, a `JavaObject` that carries its element descriptor. An array
  result arrives as one, and `toList()` reads it as the matching Dart type: a
  typed list for primitives (`Int32List`, `Float64List`, …), `List<String?>` for
  `String[]`, unboxed values for a wrapper array, and nested `JavaArray`s for
  `int[][]`.
- A Dart `List` may now be passed for any array parameter or field, nested lists
  included; the temporary array is released after the call.
- `JavaArray.of`, `.sized`, and typed factories (`ofInts`, `ofStrings`, …),
  with `[]` / `[]=` element access.
- New raw helpers on `JvmArrays`: `newArray`, `arrayToList`, `getArrayElement`,
  `setArrayElement`, `getStringArray`, `getObjectArray`, `elementClass`.

### Boxed primitives

- A Dart `bool`, `int` or `double` passed where a wrapper (`Ljava/lang/Integer;`
  …) or an erased type (`Object`, `Number`, `Comparable`, `Serializable`) is
  declared is boxed automatically and released afterwards. Generic APIs —
  `List.add`, `Map.put` — take plain Dart values now.
- For an erased parameter the wrapper is *inferred*: `bool` → `Boolean`,
  `double` → `Double`, `int` → `Integer` when it fits in 32 bits, else `Long`.
  `jvm.boxLong` and friends override it when the width is observable.
- `JvmBoxing` on `Jvm`: `box`, `boxAs`, `boxInt`/`boxLong`/…, `unbox`,
  `unboxAs`, `wrapperOf`, `canBox`, `isJavaString`; `JavaWrapper` names the
  eight wrapper classes. Wrapper classes and their ids are resolved once per VM.
- `JavaObject.toDart()` converts a value whose declared type was only `Object`,
  by asking the VM what it actually is.

### Performance

- `JavaClass` caches every `jmethodID`/`jfieldID` it resolves — ids stay valid
  while the class is loaded, which the class reference guarantees — so a call in
  a loop pays for `GetMethodID` once rather than once per invocation.
- `JavaObject` holds the runtime class it resolves instead of looking it up and
  releasing it on every call, field read and field write.
- `JavaClass.name` is resolved lazily; wrapping a `jclass` no longer costs three
  JNI calls for a name that is usually only used in error messages.

### Also

- `JavaObject.isInstanceOf`, `JavaClass.methodId` / `staticMethodId` /
  `fieldId` / `staticFieldId` (cached), and `JavaClass.cachedMemberCount`.
- Calling a method or touching a field on a Java `null` now throws a `JniError`
  instead of handing a null `jobject` to JNI, where it is undefined behaviour.

### Breaking

- A method or field *declared* to return a primitive wrapper is now unboxed:
  `callStatic('valueOf', '(I)Ljava/lang/Integer;', [42])` returns `42`, not a
  `JavaObject`. Use `jvm.boxInt(42)` to get the object.
- A result declared as an array type is now a `JavaArray` rather than a plain
  `JavaObject`. `JavaArray` is a `JavaObject`, so an `as JavaObject` cast still
  holds; `as JavaObject` followed by raw array calls on `.ref` still works too.
- `JavaClass`'s third constructor argument is optional, and `release()` clears
  the member cache.

## 1.0.0

Initial release: a complete, tested Dart↔Java bridge built on `dart:ffi` alone.

### JVM lifecycle

- `Jvm.startOrAttach` boots a JVM, or attaches to the one the process already
  has (via `JNI_GetCreatedJavaVMs`), so multiple isolates can share one VM.
- Survives the startup race: when two threads call `JNI_CreateJavaVM` at once,
  the loser waits for the winner's VM to be published instead of failing with
  `JNI_EEXIST`.
- `JNIEnv*` is re-resolved per call through `GetEnv`, attaching the current
  thread when needed — a Dart isolate is not pinned to an OS thread, so a
  cached env would be a latent crash.
- `Jvm.destroy`, `detachCurrentThread`, `version`, and `fnSlot` as an escape
  hatch for unwrapped JNI functions.

### Calls and members

- Classes by dotted or JNI name, including nested (`Outer$Inner`) classes;
  `getObjectClass`, `getSuperclass`, `isInstanceOf`, `isAssignableFrom`.
- Constructors and instance/static methods for all ten JNI return types
  (`void`, the eight primitives, and references).
- Instance and static fields, read and written, for all types.
- Argument coercion driven by the parsed method signature, which is what makes
  a Dart `double` land as either `jfloat` or `jdouble` correctly.

### Data

- Strings via the UTF-16 (`jchar`) family, so astral characters and embedded
  NULs survive a round trip — JNI's "UTF-8" is *modified* UTF-8 and does not.
- Arrays: creation, length, bulk region read/write for all eight primitive
  types, plus object arrays with null elements.

### Errors and references

- Java throwables become `JavaException` carrying the class name, message and
  Java stack trace, with the pending exception always cleared first.
- `throwJava` raises a Java exception from Dart.
- Explicit `JavaRef` ownership with local/global references, `toGlobal`,
  `isSameObject`, scoped `localFrame`, and a clear error on use-after-release
  instead of a dangling pointer.

### Ergonomics

- `JavaClass` / `JavaObject` dispatch from the signature string, convert Dart
  arguments (including `String`), and release temporaries automatically.
- `JniSignature` parses and builds descriptors, rejecting malformed ones at the
  call site rather than as a confusing `NoSuchMethodError` from the VM.
- `searchLibjvm` / `defaultLibjvmPath` locate a JDK and report every path tried.
