# greeter

The smallest useful [`java_interop`](../../) program, as a standalone project.

It boots a JVM, constructs a `com.nfeflash.example.Greeter`, calls an instance
method and a static one, and catches a Java `ArithmeticException` as a Dart
[`JavaException`]. That is the whole interop loop in about thirty lines.

Its `pubspec.yaml` depends on `java_interop` **by path**, which is the point of
having it be its own project: it consumes the package the way anything else
would — through the public API, with nothing under `lib/src` reachable — so a
gap in what the package exports breaks here first.

It is also self-contained. Everything it needs to build and run is in this
directory, and it shares nothing with the test suite:

```
example/greeter/
  java/com/nfeflash/example/Greeter.java   the class it calls
  build.sh                                 javac + jar -> build/greeter.jar
  java_home.sh                             JDK discovery
  bin/greeter_example.dart                 the program
  pubspec.yaml                             java_interop: {path: ../../}
```

## Running it

```sh
./build.sh              # once: compiles java/ into build/greeter.jar
dart pub get
dart run bin/greeter_example.dart
```

Or, from the repository root, which does all three:

```sh
./run.sh
```

The jar is resolved next to this project rather than next to the working
directory, so `dart run` behaves the same from here or from the root. Pass an
explicit path to override it:

```sh
dart run bin/greeter_example.dart /path/to/greeter.jar
```

## Expected output

```
Hello, Dart! (from Java 21.0.12)
Greeter.add(2, 40) = 42
Greeter.divide(1, 0) threw: JavaException: java.lang.ArithmeticException: / by zero
```

The Java source it calls is
[`java/com/nfeflash/example/Greeter.java`](java/com/nfeflash/example/Greeter.java),
here in this project. Nothing in the test suite compiles or loads it, and this
project loads nothing the test suite builds.

[`JavaException`]: ../../lib/src/errors.dart
