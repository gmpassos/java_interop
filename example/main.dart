/// A tour of the whole API surface, runnable end to end.
///
/// This is the reference sweep: every feature, once, against the test fixtures.
/// For a specific task, the neighbouring examples are the better read —
/// `jdk_apis.dart` for real JDK libraries, `collections.dart` for `java.util`,
/// `performance.dart` for calling Java in a loop. See `example.md`.
///
/// ```sh
/// ./test/build.sh && dart run example/main.dart
/// ```
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';

/// Prints an aligned `label = value` line, so the output reads as a table.
void _show(String label, Object? value) => print('${label.padRight(18)}$value');

void main(List<String> arguments) {
  final jar = arguments.isNotEmpty
      ? arguments.first
      : 'test/build/fixtures.jar';
  if (!File(jar).existsSync()) {
    stderr.writeln('Jar not found: $jar\nBuild it first with ./test/build.sh');
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
  _show('Math.abs(-5)', math.callStatic('abs', '(I)I', [-5]));
  _show('Math.sqrt(16)', math.callStatic('sqrt', '(D)D', [16.0]));
  _show('Math.PI', math.getStaticField('PI', JniType.double_));
  math.release();

  final list = JavaClass.forName(jvm, 'java.util.ArrayList');
  final instance = list.newInstance();
  instance.call('add', '(Ljava/lang/Object;)Z', ['first']);
  instance.call('add', '(Ljava/lang/Object;)Z', ['second']);
  _show(
    'ArrayList',
    '${instance.javaToString()} (size ${instance.call('size', '()I')})',
  );
  instance.release();
  list.release();
}

void _fixtures(Jvm jvm) {
  print('\n--- constructors, methods and fields ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  final object = fixtures.newInstance('(Ljava/lang/String;I)V', ['demo', 7]);
  _show('label', object.call('getLabel', '()Ljava/lang/String;'));
  _show('number', object.call('getNumber', '()I'));

  // Every primitive in one call, to show jvalue packing.
  _show(
    'mixed',
    object.call('mixed', '(ZBCSIJFD)Ljava/lang/String;', [
      true,
      -128,
      0x0041,
      -32768,
      2147483647,
      9223372036854775807,
      1.5,
      2.5,
    ]),
  );

  // Fields, read and written.
  _show('intField', object.getField('intField', JniType.int_));
  object.setField('stringField', JniType.string, 'written from Dart');
  _show('stringField', object.getField('stringField', JniType.string));
  _show(
    'staticIntField',
    fixtures.getStaticField('staticIntField', JniType.int_),
  );

  object.release();
  fixtures.release();
}

void _arrays(Jvm jvm) {
  print('\n--- arrays ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  // An array result knows its element type and reads back as a typed list.
  final fromJava = fixtures.callStatic('intArray', '()[I') as JavaArray;
  _show('int[] from Java', fromJava.toList());
  fromJava.release();

  // A Dart List is converted for you, and the temporary array released.
  _show(
    'sumInts',
    fixtures.callStatic('sumInts', '([I)I', [
      [1, 2, 3, 4],
    ]),
  );
  const joinStrings = '([Ljava/lang/String;)Ljava/lang/String;';
  _show(
    'joinStrings',
    fixtures.callStatic('joinStrings', joinStrings, [
      ['a', 'b', 'c'],
    ]),
  );
  _show(
    'sumNested',
    fixtures.callStatic('sumNested', '([[I)I', [
      [
        [1, 2],
        [3],
      ],
    ]),
  );

  // Or build one explicitly, to keep it across several calls and mutate it.
  final ints = JavaArray.ofInts(jvm, [10, 20, 30]);
  ints[0] = 100;
  _show('JavaArray', '${ints.toList()} (length ${ints.length})');
  _show('sumInts(that)', fixtures.callStatic('sumInts', '([I)I', [ints]));
  ints.release();

  // A String[] comes back as Dart strings, null elements included.
  final strings =
      fixtures.callStatic('stringArray', '()[Ljava/lang/String;') as JavaArray;
  _show('String[]', strings.toList());
  strings.release();

  fixtures.release();
}

void _boxing(Jvm jvm) {
  print('\n--- boxed primitives ---');

  final fixtures = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');

  // A declared wrapper is boxed on the way in and unboxed on the way out.
  _show(
    'unboxInteger(42)',
    fixtures.callStatic('unboxInteger', '(Ljava/lang/Integer;)I', [42]),
  );
  _show(
    'boxInteger(7)',
    fixtures.callStatic('boxInteger', '(I)Ljava/lang/Integer;', [7]),
  );

  // For an erased `Object` parameter the wrapper is inferred from the value.
  const classOf = '(Ljava/lang/Object;)Ljava/lang/String;';
  _show('classOf(42)', fixtures.callStatic('classOf', classOf, [42]));
  _show('classOf(2^40)', fixtures.callStatic('classOf', classOf, [1 << 40]));
  _show('classOf(1.5)', fixtures.callStatic('classOf', classOf, [1.5]));
  _show('classOf(true)', fixtures.callStatic('classOf', classOf, [true]));

  // Which means a generic collection can be driven with plain Dart values.
  final listClass = JavaClass.forName(jvm, 'java.util.ArrayList');
  final list = listClass.newInstance();
  for (final value in [1, 2, 3]) {
    list.call('add', '(Ljava/lang/Object;)Z', [value]);
  }
  _show(
    'sumList([1,2,3])',
    fixtures.callStatic('sumList', '(Ljava/util/List;)I', [list]),
  );

  // And what a method declared to return `Object` actually handed back.
  final first = list.call('get', '(I)Ljava/lang/Object;', [0]) as JavaObject;
  _show('list.get(0)', '${first.toDart()} (${first.type.name})');
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
    _show('caught', e);
    _show('isA Arithmetic', e.isA('ArithmeticException'));
    _show('stack trace', e.stackTraceText?.split('\n').first);
  }

  // The VM is immediately usable again: the pending exception was cleared.
  _show('still working', fixtures.callStatic('staticSum', '(II)I', [2, 2]));

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
  _show('1000 in a frame', 'total length $total');

  // A global reference outlives the frame.
  late JavaRef kept;
  jvm.localFrame(() {
    kept = jvm.newString('survives the frame').toGlobal();
  });
  _show('global', jvm.stringFrom(kept));
  kept.release();

  print('\nSee performance.dart for what this costs in a hot loop.');
}
