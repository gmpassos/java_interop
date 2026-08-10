# Changelog

## 1.1.1

Repository, examples and CI. **No library changes** — the only edit under `lib/`
is a corrected doc comment, so upgrading from 1.1.0 changes nothing at runtime.

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
