/// The smallest useful java_interop program.
///
/// A standalone project: its pubspec depends on `java_interop` by path, so this
/// is what using the package from the outside actually looks like.
///
/// ```sh
/// ../../build.sh                      # once, to compile the fixtures jar
/// dart pub get
/// dart run bin/greeter_example.dart [path/to/java_interop.jar]
/// ```
///
/// Or from the repository root, which builds the jar first: `./run.sh`.
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';

void main(List<String> arguments) {
  final jar = arguments.isNotEmpty ? arguments.first : _findFixturesJar();

  if (jar == null || !File(jar).existsSync()) {
    stderr.writeln(
      'Fixtures jar not found${jar == null ? '' : ' at $jar'}.\n'
      'Build it first with ./build.sh in the repository root, or pass the '
      'path:\n'
      '  dart run bin/greeter_example.dart path/to/java_interop.jar',
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

/// Looks for `build/java_interop.jar` from the current directory upwards.
///
/// This project sits three levels below the repository root, so a plain
/// relative path would only work from one working directory. Walking up means
/// `dart run` behaves the same from here, from `example/`, or from the root.
String? _findFixturesJar() {
  var directory = Directory.current.absolute;

  for (var i = 0; i < 6; i++) {
    final candidate = File('${directory.path}/build/java_interop.jar');
    if (candidate.existsSync()) return candidate.path;

    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}
