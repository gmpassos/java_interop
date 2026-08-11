# Examples

Six runnable programs, smallest first. Only the greeter needs a jar — it builds
its own. The rest call classes the JVM already has on its bootstrap loader, so
`dart run` is the whole setup.

| Example | What it shows | Needs a jar |
| --- | --- | --- |
| [`greeter/`](greeter/) | The smallest useful program: boot a JVM, construct an object, call a method, catch a Java exception. **Its own project**, depending on `java_interop` by path — what using the package from outside looks like. Start here. | its own |
| [`jdk_apis.dart`](jdk_apis.dart) | Real work with libraries every JDK ships: SHA-256 (`MessageDigest`), locale-aware currency (`NumberFormat` + `Locale`), and a deflate/inflate round trip (`java.util.zip`) using a Java array as a shared output buffer. | no |
| [`collections.dart`](collections.dart) | `ArrayList` and `HashMap` driven with plain Dart values, because generics erase to `Object` and boxing handles the rest. Ends with two reusable converters, `dartListFrom` and `dartMapFrom`. | no |
| [`performance.dart`](performance.dart) | Calling Java in a loop: holding a `JavaClass` so its member-id cache pays off, and scoping local references with `localFrame`. Prints measured timings. | no |
| [`threads.dart`](threads.dart) | Java's threads, from a single-threaded isolate: `Arrays.parallelSort` on every core, a Dart `Runnable` on a `java.lang.Thread` and in a pool (queued, one at a time, on the isolate), a `Callable` refused because no worker can be answered, `jvm.synchronized`, and waiting on a latch without deadlocking. | no |
| [`main.dart`](main.dart) | The reference sweep — every feature once, against the JDK: constructors, all eight primitives in and out, static and instance fields, arrays (including one Java sorts in place), boxing, exceptions, references. | no |

## Layout

`greeter/` is a **standalone, self-contained project**: its own `pubspec.yaml`,
`analysis_options.yaml`, [`README`](greeter/README.md), Java source, build
script and JDK discovery. It depends on `java_interop` by path, so it exercises
the package through its public API the way a real consumer would — nothing under
`lib/src` is reachable from it, and a gap in the package's exports fails there
before it fails for anyone else.

It shares nothing with the test suite in either direction: the suite owns
`test/java/` and builds `test/build/fixtures.jar`, the greeter owns
`example/greeter/java/` and builds `example/greeter/build/greeter.jar`, and
neither compiles or loads the other's.

The other five are plain files belonging to the parent package, which keeps them
one `dart run` away with no separate `pub get`. None of them loads a jar: the
tour is written against the JDK precisely so that nothing in `example/` depends
on anything the test suite builds.

```
example/
  example.md              this file
  main.dart               ┐
  jdk_apis.dart           │
  collections.dart        │ parent package
  performance.dart        │
  threads.dart            ┘
  greeter/                standalone project
    pubspec.yaml            java_interop: {path: ../../}
    analysis_options.yaml
    README.md
    build.sh                javac + jar -> build/greeter.jar
    java_home.sh            JDK discovery
    java/com/nfeflash/example/Greeter.java
    bin/greeter_example.dart
```

## Running them

Five of them need nothing but a JDK on the machine:

```sh
dart run example/main.dart
dart run example/jdk_apis.dart
dart run example/collections.dart
dart run example/performance.dart
dart run example/threads.dart
```

The greeter builds its own jar first, which `./run.sh` does for you:

```sh
./run.sh
```

Or built and run entirely as the separate project it is:

```sh
cd example/greeter
./build.sh
dart pub get
dart run bin/greeter_example.dart
```

If no JDK can be found, every example says so and exits rather than failing
inside `DynamicLibrary.open`. Point `JAVA_HOME` at a JDK — not a JRE, which has
no `libjvm` — if discovery does not find yours:

```sh
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
```

## What to read for a given task

- **Getting anything at all to run** — `greeter/`.
- **Calling a method whose descriptor you already know** — `main.dart`, the
  `_classesAndMethods` section.
- **Getting a primitive across correctly** — `main.dart`, `_everyPrimitive`:
  all eight, where the text that comes back proves each landed in the right
  bytes of its `jvalue` slot.
- **Passing or receiving an array** — `jdk_apis.dart` (`MessageDigest.digest`
  takes and returns `byte[]`; `Deflater` writes into one you own).
- **Anything generic** — `collections.dart`. Every `java.util` signature is
  `Object`-shaped after erasure, and that is the case boxing exists for.
- **A loop that runs more than a few thousand times** — `performance.dart`.
- **Anything with a thread in it** — an `ExecutorService`, a listener a Java
  library calls back on its own thread, state two threads share, or a wait that
  must not deadlock — `threads.dart`.
- **Something this binding does not wrap** — the "Dropping to raw JNI" section
  of the [README](../README.md#dropping-to-raw-jni).
