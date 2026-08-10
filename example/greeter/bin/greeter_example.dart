/// The smallest useful java_interop program.
///
/// A standalone project: it owns the Java class it calls (`java/`), the script
/// that compiles it (`build.sh`), the JDK discovery that script uses
/// (`java_home.sh`), and a pubspec that depends on `java_interop` by path — so
/// this is what using the package from the outside actually looks like.
///
/// ```sh
/// ./build.sh                          # once, to compile java/ into build/greeter.jar
/// dart pub get
/// dart run bin/greeter_example.dart [path/to/greeter.jar]
/// ```
///
/// Or, from the repository root: `./run.sh`, which does all three.
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';

void main(List<String> arguments) {
  final jar = arguments.isNotEmpty ? arguments.first : _defaultJar();

  if (!File(jar).existsSync()) {
    stderr.writeln(
      'Jar not found: $jar\n'
      'Build it first with ./build.sh in this directory, or pass the path:\n'
      '  dart run bin/greeter_example.dart path/to/greeter.jar',
    );
    exitCode = 1;
    return;
  }

  final jvm = Jvm.startOrAttach(classPath: [jar]);

  final greeter = JavaClass.forName(jvm, 'com.nfeflash.example.Greeter');
  final instance = greeter.newInstance('(Ljava/lang/String;)V', ['Dart']);

  print(instance.call('greet', '()Ljava/lang/String;'));
  print('Greeter.add(2, 40) = ${greeter.callStatic('add', '(II)I', [2, 40])}');

  try {
    greeter.callStatic('divide', '(II)I', [1, 0]);
    print('Greeter.divide(1, 0) did not throw -- unexpected');
  } on JavaException catch (e) {
    print('Greeter.divide(1, 0) threw: $e');
  }

  instance.release();
  greeter.release();

  // Not destroying the VM: HotSpot cannot start another one in this process,
  // and the process is about to exit anyway.
}

/// `build/greeter.jar`, resolved next to this project rather than next to
/// whatever the working directory happens to be.
///
/// `bin/greeter_example.dart` is one level below the project root, so the jar
/// this project builds is always at `../build/greeter.jar` from the script —
/// which makes `dart run` behave the same from here or from the repository
/// root.
String _defaultJar() {
  final script = File.fromUri(Platform.script).absolute;
  final projectRoot = script.parent.parent;
  return '${projectRoot.path}${Platform.pathSeparator}'
      'build${Platform.pathSeparator}greeter.jar';
}
