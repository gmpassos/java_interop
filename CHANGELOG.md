# Changelog

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
