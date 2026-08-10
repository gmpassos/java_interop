/// Calls `com.nfeflash.example.Greeter` out of `build/java_interop.jar`.
///
/// ```sh
/// ./run.sh
/// # or, with JAVA_HOME already exported:
/// dart run bin/greeter_example.dart [path/to/java_interop.jar]
/// ```
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';

void main(List<String> arguments) {
  final jar = arguments.isNotEmpty ? arguments.first : 'build/java_interop.jar';

  if (!File(jar).existsSync()) {
    stderr.writeln('Jar not found: $jar\nBuild it first with ./build.sh');
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
