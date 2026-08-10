# greeter

The smallest useful [`java_interop`](../../) program, as a standalone project.

It boots a JVM, constructs a `com.nfeflash.example.Greeter`, calls an instance
method and a static one, and catches a Java `ArithmeticException` as a Dart
[`JavaException`]. That is the whole interop loop in about thirty lines.

Its `pubspec.yaml` depends on `java_interop` **by path**, which is the point of
having it be its own project: it consumes the package the way anything else
would — through the public API, with nothing under `lib/src` reachable — so a
gap in what the package exports breaks here first.

## Running it

```sh
../../build.sh          # once: compiles the Java fixtures into build/java_interop.jar
dart pub get
dart run bin/greeter_example.dart
```

Or, from the repository root, which builds the jar for you:

```sh
./run.sh
```

The jar is found by walking up from the working directory, so either works.
Pass an explicit path to override it:

```sh
dart run bin/greeter_example.dart /path/to/java_interop.jar
```

## Expected output

```
Hello, Dart! (from Java 21.0.12)
Greeter.add(2, 40) = 42
Greeter.divide(1, 0) threw: JavaException: java.lang.ArithmeticException: / by zero
```

The Java source it calls is
[`java/com/nfeflash/example/Greeter.java`](../../java/com/nfeflash/example/Greeter.java),
which lives in the parent project because the test suite uses it too.

[`JavaException`]: ../../lib/src/errors.dart
