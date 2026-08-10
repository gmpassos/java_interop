# Examples

Five runnable programs, smallest first. Three of them need no jar and no class
path at all — they call classes the JVM already has on its bootstrap loader —
so `dart run` is the whole setup.

| Example | What it shows | Needs the jar |
| --- | --- | --- |
| [`bin/greeter_example.dart`](../bin/greeter_example.dart) | The smallest useful program: boot a JVM, construct an object, call a method, catch a Java exception. Start here. | yes |
| [`jdk_apis.dart`](jdk_apis.dart) | Real work with libraries every JDK ships: SHA-256 (`MessageDigest`), locale-aware currency (`NumberFormat` + `Locale`), and a deflate/inflate round trip (`java.util.zip`) using a Java array as a shared output buffer. | no |
| [`collections.dart`](collections.dart) | `ArrayList` and `HashMap` driven with plain Dart values, because generics erase to `Object` and boxing handles the rest. Ends with two reusable converters, `dartListFrom` and `dartMapFrom`. | no |
| [`performance.dart`](performance.dart) | Calling Java in a loop: holding a `JavaClass` so its member-id cache pays off, and scoping local references with `localFrame`. Prints measured timings. | no |
| [`main.dart`](main.dart) | The reference sweep — every feature once, against the test fixtures: constructors, all ten return types, fields, arrays, boxing, exceptions, references. | yes |

## Running them

The three JDK-only examples need nothing but a JDK on the machine:

```sh
dart run example/jdk_apis.dart
dart run example/collections.dart
dart run example/performance.dart
```

The two that use the `com.nfeflash.example` fixtures need the jar built first:

```sh
./build.sh                      # compiles java/ into build/java_interop.jar
dart run example/main.dart
./run.sh                        # builds if needed, then the greeter
```

If no JDK can be found, every example says so and exits rather than failing
inside `DynamicLibrary.open`. Point `JAVA_HOME` at a JDK — not a JRE, which has
no `libjvm` — if discovery does not find yours:

```sh
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
```

## What to read for a given task

- **Calling a method whose descriptor you already know** — `main.dart`, the
  `_fixtures` section.
- **Passing or receiving an array** — `jdk_apis.dart` (`MessageDigest.digest`
  takes and returns `byte[]`; `Deflater` writes into one you own).
- **Anything generic** — `collections.dart`. Every `java.util` signature is
  `Object`-shaped after erasure, and that is the case boxing exists for.
- **A loop that runs more than a few thousand times** — `performance.dart`.
- **Something this binding does not wrap** — the "Dropping to raw JNI" section
  of the [README](../README.md#dropping-to-raw-jni).
