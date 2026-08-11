/// A tour of the whole API surface, runnable end to end — against the JDK.
///
/// Every feature once, using only classes the JVM already has on its bootstrap
/// loader, so this needs no jar and no class path. That is also the point: the
/// binding is not tied to fixtures built for it, and neither is your code.
///
/// For a specific task the neighbouring examples are the better read —
/// `jdk_apis.dart` for real JDK libraries, `collections.dart` for `java.util`,
/// `performance.dart` for calling Java in a loop, `greeter/` for the smallest
/// possible program. See `example.md`.
///
/// ```sh
/// dart run example/main.dart
/// ```
library;

import 'package:java_interop/java_interop.dart';

/// Prints an aligned `label  value` line, so the output reads as a table.
void _show(String label, Object? value) => print('${label.padRight(22)}$value');

void main() {
  final Jvm jvm;
  try {
    jvm = Jvm.startOrAttach();
  } on JniError catch (e) {
    print('No JVM available:\n$e');
    return;
  }
  print('JNI version: 0x${jvm.version.toRadixString(16)}');

  _classesAndMethods(jvm);
  _declarations(jvm);
  _everyPrimitive(jvm);
  _fields(jvm);
  _arrays(jvm);
  _boxing(jvm);
  _exceptions(jvm);
  _references(jvm);
  _proxies(jvm);
}

/// Constructors, instance methods, static methods, and the types they return.
void _classesAndMethods(Jvm jvm) {
  print('\n--- classes, constructors and methods ---');

  // A constructor taking a String, then instance methods on the result.
  final builderClass = JavaClass.forName(jvm, 'java.lang.StringBuilder');
  final builder = builderClass.newInstance('(Ljava/lang/String;)V', ['Hello']);

  builder.call('append', '(Ljava/lang/String;)Ljava/lang/StringBuilder;', [
    ', Dart',
  ]);
  builder.call('append', '(C)Ljava/lang/StringBuilder;', ['!'.codeUnitAt(0)]);

  _show('StringBuilder', builder.javaToString());
  _show('  .length() -> I', builder.call('length', '()I'));

  // A reference return: a JavaObject you own and must release. It is the same
  // builder, since reverse() returns `this`.
  final reversed =
      builder.call('reverse', '()Ljava/lang/StringBuilder;') as JavaObject;
  _show('  .reverse() -> obj', reversed.javaToString());
  reversed.release();

  // A void return, and a static method on a different class.
  builder.call('setLength', '(I)V', [0]);
  _show('  .setLength(0) -> V', 'length now ${builder.call('length', '()I')}');

  final math = JavaClass.forName(jvm, 'java.lang.Math');
  _show('Math.abs(-5)', math.callStatic('abs', '(I)I', [-5]));
  _show('Math.sqrt(16)', math.callStatic('sqrt', '(D)D', [16.0]));

  // The runtime class of an object, resolved lazily and then held.
  _show('builder.type.name', builder.type.name);

  final charSequence = JavaClass.forName(jvm, 'java.lang.CharSequence');
  _show('is a CharSequence', builder.isInstanceOf(charSequence));
  charSequence.release();

  builder.release();
  math.release();
  builderClass.release();
}

/// The same calls again, written as Java rather than as descriptors.
///
/// `(Ljava/lang/String;I)V` is easy to get wrong in ways that only surface as a
/// `NoSuchMethodError` from inside the VM. A declaration is what `javap` prints,
/// so it can be pasted in unedited.
void _declarations(Jvm jvm) {
  print('\n--- signatures written as Java ---');

  final builderClass = JavaClass.forName(jvm, 'java.lang.StringBuilder');

  // Name and types in one declaration, instead of ('append', '(I)L…;').
  final builder = builderClass.newJava('(String)', ['count: ']);

  // append returns `this`, so the result is a reference to release.
  final appended =
      builder.callJava('StringBuilder append(int)', [42]) as JavaObject;
  appended.release();

  _show('newJava + callJava', builder.javaToString());
  _show('  .length()', builder.callJava('int length()'));

  // What each declaration compiles to.
  _show('jsig', jsig('int add(int, int)'));
  _show('  with modifiers', jsig('public static int add(int a, int b)'));
  _show('  generics erased', jsig('java.util.List<String> subList(int, int)'));
  _show('  varargs', jsig('String format(String, Object...)'));
  _show('  a constructor', jsig('(String, int)'));
  _show('jtype', '${jtype('int[][]')}  ${jtype('String')}');

  // Or built from types, which cannot be malformed and can be const.
  const add = JSig.of([JType.int_, JType.int_], returns: JType.int_);
  _show('JSig.of', add.descriptor);
  _show('JType.of(...).array', JType.of('java.util.List').array.descriptor);

  builder.release();
  builderClass.release();
}

/// Each of the eight primitives passed across the boundary and read back.
///
/// `String.valueOf` is overloaded per primitive, so the descriptor alone
/// decides which one is called — and the text that comes back proves the value
/// landed in the right bytes of its `jvalue` slot. A `float` read as a `double`
/// would not print `1.5`.
void _everyPrimitive(Jvm jvm) {
  print('\n--- every primitive, in and out ---');

  final string = JavaClass.forName(jvm, 'java.lang.String');
  const to = 'Ljava/lang/String;';

  _show('boolean  (Z)', string.callStatic('valueOf', '(Z)$to', [true]));
  _show('char     (C)', string.callStatic('valueOf', '(C)$to', [0x00e7]));
  _show('int      (I)', string.callStatic('valueOf', '(I)$to', [2147483647]));
  _show(
    'long     (J)',
    string.callStatic('valueOf', '(J)$to', [9223372036854775807]),
  );
  _show('float    (F)', string.callStatic('valueOf', '(F)$to', [1.5]));
  _show(
    'double   (D)',
    string.callStatic('valueOf', '(D)$to', [2.718281828459045]),
  );

  // byte and short have no valueOf overload — they would widen to int.
  final byte = JavaClass.forName(jvm, 'java.lang.Byte');
  final short = JavaClass.forName(jvm, 'java.lang.Short');
  _show('byte     (B)', byte.callStatic('toString', '(B)$to', [-128]));
  _show('short    (S)', short.callStatic('toString', '(S)$to', [-32768]));

  // Several widths packed into one argument array, in one call.
  final greeting = JavaObject(jvm, jvm.newString('Hello World'));
  _show(
    'regionMatches',
    greeting.call('regionMatches', '(ZI${to}II)Z', [true, 6, 'WORLD', 0, 5]),
  );

  greeting.release();
  short.release();
  byte.release();
  string.release();
}

/// Static and instance fields, read and written.
void _fields(Jvm jvm) {
  print('\n--- fields ---');

  // Static reads cover all eight primitive descriptors.
  for (final (className, field, descriptor) in const [
    ('java.lang.Byte', 'MIN_VALUE', JniType.byte),
    ('java.lang.Short', 'MAX_VALUE', JniType.short),
    ('java.lang.Integer', 'MAX_VALUE', JniType.int_),
    ('java.lang.Long', 'MAX_VALUE', JniType.long),
    ('java.lang.Float', 'MAX_VALUE', JniType.float),
    ('java.lang.Double', 'MAX_VALUE', JniType.double_),
    ('java.lang.Character', 'MAX_VALUE', JniType.char),
    ('java.lang.Boolean', 'TRUE', 'Ljava/lang/Boolean;'),
  ]) {
    final clazz = JavaClass.forName(jvm, className);
    final short = className.split('.').last;
    _show('$short.$field', clazz.getStaticField(field, descriptor));
    clazz.release();
  }

  // Instance fields, read and written. java.io.StreamTokenizer is the rare
  // java.base class with public mutable fields: ttype (int), nval (double)
  // and sval (String).
  final readerClass = JavaClass.forName(jvm, 'java.io.StringReader');
  final reader = readerClass.newInstance('(Ljava/lang/String;)V', ['42 hello']);

  final tokenizerClass = JavaClass.forName(jvm, 'java.io.StreamTokenizer');
  final tokenizer = tokenizerClass.newInstance('(Ljava/io/Reader;)V', [reader]);

  tokenizer.call('nextToken', '()I');
  _show('tokenizer.nval', tokenizer.getField('nval', JniType.double_));

  tokenizer.call('nextToken', '()I');
  _show('tokenizer.sval', tokenizer.getField('sval', JniType.string));

  tokenizer.setField('ttype', JniType.int_, 99);
  _show(
    'tokenizer.ttype',
    '${tokenizer.getField('ttype', JniType.int_)} '
        '(written from Dart)',
  );

  tokenizer.release();
  tokenizerClass.release();
  reader.release();
  readerClass.release();
}

/// Arrays in both directions, including one Java mutates in place.
void _arrays(Jvm jvm) {
  print('\n--- arrays ---');

  final text = JavaObject(jvm, jvm.newString('gamma,alpha,beta'));

  // Java-created arrays arrive as a JavaArray that knows its element type.
  final parts =
      text.call('split', '(Ljava/lang/String;)[Ljava/lang/String;', [','])
          as JavaArray;
  _show('"…".split(",")', parts.toList());

  final chars = text.call('toCharArray', '()[C') as JavaArray;
  _show('"…".toCharArray()', '${chars.length} UTF-16 code units');

  final bytes = text.call('getBytes', '()[B') as JavaArray;
  _show('"…".getBytes()', '${bytes.length} bytes, first ${bytes[0]}');

  final arrays = JavaClass.forName(jvm, 'java.util.Arrays');

  // A Dart List converts on the way in, and the temporary array is released.
  _show(
    'Arrays.toString',
    arrays.callStatic('toString', '([I)Ljava/lang/String;', [
      [3, 1, 2],
    ]),
  );

  // A JavaArray held across calls, sorted *in place* by Java: the array is
  // shared, not copied in and forgotten.
  final numbers = JavaArray.ofInts(jvm, [5, 3, 9, 1]);
  arrays.callStatic('sort', '([I)V', [numbers]);
  _show('Arrays.sort(int[])', numbers.toList());
  numbers[0] = 100;
  _show('  then numbers[0]=100', numbers.toList());

  // Nested arrays: the element descriptor is itself an array type.
  final grid = JavaArray.of(jvm, '[I', [
    [1, 2],
    [3],
  ]);
  _show(
    'Arrays.deepToString',
    arrays.callStatic(
      'deepToString',
      '([Ljava/lang/Object;)'
          'Ljava/lang/String;',
      [grid],
    ),
  );
  final firstRow = grid[0] as JavaArray;
  _show('  grid[0] is a', '${firstRow.descriptor} -> ${firstRow.toList()}');

  firstRow.release();
  grid.release();
  numbers.release();
  arrays.release();
  bytes.release();
  chars.release();
  parts.release();
  text.release();
}

/// Boxed primitives, in both directions.
void _boxing(Jvm jvm) {
  print('\n--- boxed primitives ---');

  final integer = JavaClass.forName(jvm, 'java.lang.Integer');

  // A declared wrapper return is unboxed to a Dart int…
  _show(
    'Integer.valueOf(7)',
    integer.callStatic('valueOf', '(I)Ljava/lang/Integer;', [7]),
  );
  // …and a null one stays null rather than becoming 0.
  _show(
    'Integer.getInteger(?)',
    integer.callStatic(
      'getInteger',
      '(Ljava/lang/String;)Ljava/lang/Integer;',
      ['no.such.property'],
    ),
  );

  // A declared wrapper *parameter* is boxed exactly: Integer.compareTo(Integer).
  final five = JavaObject(jvm, jvm.boxInt(5));
  _show(
    '5.compareTo(7)',
    five.call('compareTo', '(Ljava/lang/Integer;)I', [7]),
  );
  five.release();

  // An erased Object parameter has its wrapper inferred from the Dart value.
  final listClass = JavaClass.forName(jvm, 'java.util.ArrayList');
  final list = listClass.newInstance();
  for (final value in [42, 1 << 40, 1.5, true, 'text']) {
    list.call('add', '(Ljava/lang/Object;)Z', [value]);
  }

  for (var i = 0; i < 5; i++) {
    final element =
        list.call('get', '(I)Ljava/lang/Object;', [i]) as JavaObject;
    _show('  list[$i]', '${element.toDart()}  (${element.type.name})');
    element.release();
  }

  list.release();
  listClass.release();
  integer.release();
}

/// Java throwables arriving as Dart exceptions.
void _exceptions(Jvm jvm) {
  print('\n--- exceptions ---');

  final integer = JavaClass.forName(jvm, 'java.lang.Integer');

  try {
    integer.callStatic('parseInt', '(Ljava/lang/String;)I', ['not a number']);
  } on JavaException catch (e) {
    _show('caught', e);
    _show('isA NumberFormat…', e.isA('NumberFormatException'));
    _show('stack trace', e.stackTraceText?.split('\n').first);
  }

  // The VM is immediately usable again: the pending exception was cleared.
  _show(
    'still working',
    integer.callStatic('parseInt', '(Ljava/lang/String;)I', ['42']),
  );

  integer.release();
}

/// Reference ownership: scoped locals, and one promoted to survive the scope.
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

/// A Java interface implemented in Dart, driving the JDK's own sort.
void _proxies(Jvm jvm) {
  print('\n--- implementing a Java interface ---');

  var compares = 0;
  final byLength = jvm.implementInterface(
    'java.util.Comparator',
    onInvoke: (call) {
      compares++;
      // Both arguments are Java Strings, so they arrive as Dart Strings.
      final a = call.args[0] as String;
      final b = call.args[1] as String;
      final byLength = a.length.compareTo(b.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    },
  );

  try {
    final words = JavaArray.ofStrings(jvm, [
      'delta',
      'a',
      'charlie',
      'be',
      'echo',
    ]);

    jvm.classFor('java.util.Arrays').callJavaStatic(
      'void sort(Object[], java.util.Comparator)',
      [words, byLength.instance],
    );

    _show('sorted by length', words.toList());
    _show('  compares made', compares);
    // Java's own view of the proxy: no handler was given for toString.
    _show(
      '  the proxy is',
      jvm.classFor('java.lang.String').callJavaStatic(
        'String valueOf(Object)',
        [byLength.instance],
      ),
    );

    words.release();
  } finally {
    // Also releases the isolate: a live proxy holds it open, since a JVM thread
    // could still queue a call to it.
    byLength.release();
  }
}
