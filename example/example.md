# Examples

Five runnable programs, smallest first. Three of them need no jar and no class
path at all — they call classes the JVM already has on its bootstrap loader —
so `dart run` is the whole setup.

| Example | What it shows | Needs the jar |
| --- | --- | --- |
| [`greeter/`](greeter/) | The smallest useful program: boot a JVM, construct an object, call a method, catch a Java exception. **Its own project**, depending on `java_interop` by path — what using the package from outside looks like. Start here. | yes |
| [`jdk_apis.dart`](jdk_apis.dart) | Real work with libraries every JDK ships: SHA-256 (`MessageDigest`), locale-aware currency (`NumberFormat` + `Locale`), and a deflate/inflate round trip (`java.util.zip`) using a Java array as a shared output buffer. | no |
| [`collections.dart`](collections.dart) | `ArrayList` and `HashMap` driven with plain Dart values, because generics erase to `Object` and boxing handles the rest. Ends with two reusable converters, `dartListFrom` and `dartMapFrom`. | no |
| [`performance.dart`](performance.dart) | Calling Java in a loop: holding a `JavaClass` so its member-id cache pays off, and scoping local references with `localFrame`. Prints measured timings. | no |
| [`main.dart`](main.dart) | The reference sweep — every feature once, against the test fixtures: constructors, all ten return types, fields, arrays, boxing, exceptions, references. | yes |

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

The other four are plain files belonging to the parent package, which keeps them
one `dart run` away with no separate `pub get`.

```
example/
  example.md              this file
  main.dart               ┐
  jdk_apis.dart           │ parent package
  collections.dart        │
  performance.dart        ┘
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

The three JDK-only examples need nothing but a JDK on the machine:

```sh
dart run example/jdk_apis.dart
dart run example/collections.dart
dart run example/performance.dart
```

The other two need a jar built first, and each builds its own:

```sh
./test/build.sh                 # test/java/ -> test/build/fixtures.jar
dart run example/main.dart

./run.sh                        # builds greeter.jar if needed, then runs it
```

`./build.sh` at the repository root builds both, by delegating to the project
that owns each.

The greeter can also be built and run entirely as the separate project it is:

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
  `_fixtures` section.
- **Passing or receiving an array** — `jdk_apis.dart` (`MessageDigest.digest`
  takes and returns `byte[]`; `Deflater` writes into one you own).
- **Anything generic** — `collections.dart`. Every `java.util` signature is
  `Object`-shaped after erasure, and that is the case boxing exists for.
- **A loop that runs more than a few thousand times** — `performance.dart`.
- **Something this binding does not wrap** — the "Dropping to raw JNI" section
  of the [README](../README.md#dropping-to-raw-jni).
