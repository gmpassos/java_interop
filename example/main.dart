/// A tour of the whole feature set, runnable end to end.
///
/// ```sh
/// ./build.sh && dart run example/main.dart
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

  // Starts a JVM, or attaches to the one this process already has.
  final jvm = Jvm.startOrAttach(classPath: [jar]);
  print('JNI version: 0x${jvm.version.toRadixString(16)}');

  _callTheJdk(jvm);
  _fixtures(jvm);
  _arrays(jvm);
  _boxing(jvm);
  _exceptions(jvm);
  _references(jvm);
}

void _callTheJdk(Jvm jvm) {
  print('\n--- calling the JDK ---');

  final math = JavaClass.forName(jvm, 'java.lang.Math');
  print('Math.abs(-5)   = ${math.callStatic('abs', '(I)I', [-5])}');
  print('Math.sqrt(16)  = ${math.callStatic('sqrt', '(D)D', [16.0])}');
  print('Math.PI        = ${math.getStaticField('PI', JniType.double_)}');
  math.release();

  final list = JavaClass.forName(jvm, 'java.util.ArrayList');
  final instance = list.newInstance();
  instance.call('add', '(Ljava/lang/Object;)Z', ['first']);
  instance.call('add', '(Ljava/lang/Object;)Z', ['second']);
  print(
    'ArrayList      = ${instance.javaToString()} '
    '(size ${instance.call('size', '()I')})',
  );
  instance.release();
  list.release();
}

void _fixtures(Jvm jvm) {
  print('\n--- constructors, methods and fields ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  final object = fixtures.newInstance('(Ljava/lang/String;I)V', ['demo', 7]);
  print('label          = ${object.call('getLabel', '()Ljava/lang/String;')}');
  print('number         = ${object.call('getNumber', '()I')}');

  // Every primitive in one call, to show jvalue packing.
  print(
    'mixed          = ${object.call('mixed', '(ZBCSIJFD)Ljava/lang/String;', [true, -128, 0x0041, -32768, 2147483647, 9223372036854775807, 1.5, 2.5])}',
  );

  // Fields, read and written.
  print('intField       = ${object.getField('intField', JniType.int_)}');
  object.setField('stringField', JniType.string, 'written from Dart');
  print('stringField    = ${object.getField('stringField', JniType.string)}');

  print(
    'staticIntField = '
    '${fixtures.getStaticField('staticIntField', JniType.int_)}',
  );

  object.release();
  fixtures.release();
}

void _arrays(Jvm jvm) {
  print('\n--- arrays ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  // An array result knows its element type and reads back as a typed list.
  final fromJava = fixtures.callStatic('intArray', '()[I') as JavaArray;
  print('int[] from Java = ${fromJava.toList()}');
  fromJava.release();

  // A Dart List is converted for you, and the temporary array released.
  print(
    'sumInts([1,2,3,4]) = ${fixtures.callStatic('sumInts', '([I)I', [
      [1, 2, 3, 4],
    ])}',
  );
  print(
    'joinStrings       = ${fixtures.callStatic('joinStrings', '([Ljava/lang/String;)Ljava/lang/String;', [
      ['a', 'b', 'c'],
    ])}',
  );

  // Or build one explicitly, to keep it across several calls.
  final ints = JavaArray.ofInts(jvm, [10, 20, 30]);
  ints[0] = 100;
  print('JavaArray         = ${ints.toList()} (length ${ints.length})');
  print(
    'sumInts(that)     = ${fixtures.callStatic('sumInts', '([I)I', [ints])}',
  );
  ints.release();

  // A String[] comes back as Dart strings, null elements included.
  final strings =
      fixtures.callStatic('stringArray', '()[Ljava/lang/String;') as JavaArray;
  print('String[]          = ${strings.toList()}');
  strings.release();

  fixtures.release();
}

void _boxing(Jvm jvm) {
  print('\n--- boxed primitives ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  // A declared wrapper is boxed on the way in and unboxed on the way out.
  print(
    'unboxInteger(42)  = '
    '${fixtures.callStatic('unboxInteger', '(Ljava/lang/Integer;)I', [42])}',
  );
  print(
    'boxInteger(7)     = '
    '${fixtures.callStatic('boxInteger', '(I)Ljava/lang/Integer;', [7])}',
  );

  // For an erased `Object` parameter the wrapper is inferred from the value.
  const classOf = '(Ljava/lang/Object;)Ljava/lang/String;';
  print('classOf(42)       = ${fixtures.callStatic('classOf', classOf, [42])}');
  print(
    'classOf(2^40)     = '
    '${fixtures.callStatic('classOf', classOf, [1 << 40])}',
  );
  print(
    'classOf(1.5)      = ${fixtures.callStatic('classOf', classOf, [1.5])}',
  );

  // Which means a generic collection can be driven with plain Dart values.
  final listClass = JavaClass.forName(jvm, 'java.util.ArrayList');
  final list = listClass.newInstance();
  for (final value in [1, 2, 3]) {
    list.call('add', '(Ljava/lang/Object;)Z', [value]);
  }
  print(
    'sumList([1,2,3])  = '
    '${fixtures.callStatic('sumList', '(Ljava/util/List;)I', [list])}',
  );

  // And what a method declared to return `Object` actually handed back.
  final first = list.call('get', '(I)Ljava/lang/Object;', [0]) as JavaObject;
  print('list.get(0)       = ${first.toDart()}');
  first.release();

  list.release();
  listClass.release();
  fixtures.release();
}

void _exceptions(Jvm jvm) {
  print('\n--- exceptions ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  try {
    fixtures.callStatic('divide', '(II)I', [1, 0]);
  } on JavaException catch (e) {
    print('caught          = $e');
    print('isA Arithmetic  = ${e.isA('ArithmeticException')}');
    print('stack trace     = ${e.stackTraceText?.split('\n').first}');
  }

  // The VM is immediately usable again: the pending exception was cleared.
  print(
    'still working   = ${fixtures.callStatic('staticSum', '(II)I', [2, 2])}',
  );

  fixtures.release();
}

void _references(Jvm jvm) {
  print('\n--- references ---');

  // A local frame reclaims everything created inside it.
  final total = jvm.localFrame(() {
    var length = 0;
    for (var i = 0; i < 1000; i++) {
      length += jvm.stringLength(jvm.newString('value $i'));
    }
    return length;
  });
  print('1000 strings in a frame, total length $total');

  // A global reference outlives the frame.
  late JavaRef kept;
  jvm.localFrame(() {
    kept = jvm.newString('survives the frame').toGlobal();
  });
  print('global          = ${jvm.stringFrom(kept)}');
  kept.release();
}
