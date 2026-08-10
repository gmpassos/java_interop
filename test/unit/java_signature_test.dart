@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

void main() {
  group('JType constants', () {
    test('the eight primitives and void', () {
      expect(JType.boolean.descriptor, 'Z');
      expect(JType.byte.descriptor, 'B');
      expect(JType.char.descriptor, 'C');
      expect(JType.short.descriptor, 'S');
      expect(JType.int_.descriptor, 'I');
      expect(JType.long.descriptor, 'J');
      expect(JType.float.descriptor, 'F');
      expect(JType.double_.descriptor, 'D');
      expect(JType.void_.descriptor, 'V');
    });

    test('common reference types', () {
      expect(JType.string.descriptor, 'Ljava/lang/String;');
      expect(JType.object.descriptor, 'Ljava/lang/Object;');
      expect(JType.boxedInt.descriptor, 'Ljava/lang/Integer;');
      expect(JType.boxedLong.descriptor, 'Ljava/lang/Long;');
    });

    test('of wraps a class name, dotted or slashed', () {
      expect(JType.of('java.util.List').descriptor, 'Ljava/util/List;');
      expect(JType.of('java/util/List').descriptor, 'Ljava/util/List;');
      expect(
        JType.of('com.example.Outer\$Inner').descriptor,
        'Lcom/example/Outer\$Inner;',
      );
    });

    test('array nests', () {
      expect(JType.int_.array.descriptor, '[I');
      expect(JType.int_.array.array.descriptor, '[[I');
      expect(JType.string.array.descriptor, '[Ljava/lang/String;');
    });

    test('isPrimitive and isReference', () {
      expect(JType.int_.isPrimitive, isTrue);
      expect(JType.int_.isReference, isFalse);
      expect(JType.string.isReference, isTrue);
      expect(JType.int_.array.isReference, isTrue);
      expect(JType.int_.array.isPrimitive, isFalse);
    });

    test('equality is by descriptor', () {
      expect(JType.of('java.lang.String'), JType.string);
      expect(JType.of('java.lang.String').hashCode, JType.string.hashCode);
      expect(JType.int_, isNot(JType.long));
    });
  });

  group('JType.parse', () {
    test('primitives', () {
      expect(JType.parse('int'), JType.int_);
      expect(JType.parse('long'), JType.long);
      expect(JType.parse('boolean'), JType.boolean);
      expect(JType.parse('void'), JType.void_);
    });

    test('a simple name resolves against java.lang', () {
      expect(JType.parse('String'), JType.string);
      expect(JType.parse('Object'), JType.object);
      expect(JType.parse('Integer'), JType.boxedInt);
    });

    test('a qualified name is taken as written', () {
      expect(JType.parse('java.util.List').descriptor, 'Ljava/util/List;');
      expect(JType.parse('com.example.Foo').descriptor, 'Lcom/example/Foo;');
    });

    test('arrays, at any depth', () {
      expect(JType.parse('int[]').descriptor, '[I');
      expect(JType.parse('int[][]').descriptor, '[[I');
      expect(JType.parse('String[]').descriptor, '[Ljava/lang/String;');
      expect(JType.parse('java.util.List[]').descriptor, '[Ljava/util/List;');
    });

    test('varargs are an array', () {
      expect(JType.parse('int...').descriptor, '[I');
      expect(JType.parse('String...').descriptor, '[Ljava/lang/String;');
    });

    test('generics are erased', () {
      expect(JType.parse('List<String>').descriptor, 'Ljava/lang/List;');
      expect(
        JType.parse(
          'java.util.Map<String, java.util.List<Integer>>',
        ).descriptor,
        'Ljava/util/Map;',
      );
    });

    test('rejects nonsense', () {
      expect(() => JType.parse(''), throwsA(isA<JniError>()));
      expect(() => JType.parse('int '), returnsNormally);
      expect(() => JType.parse('void[]'), throwsA(isA<JniError>()));
      expect(() => JType.parse('not a type'), throwsA(isA<JniError>()));
      expect(() => JType.parse('List<String'), throwsA(isA<JniError>()));
    });
  });

  group('JSig', () {
    test('builds a descriptor', () {
      expect(
        const JSig.of([JType.int_, JType.int_], returns: JType.int_).descriptor,
        '(II)I',
      );
      expect(const JSig.of([]).descriptor, '()V');
      expect(
        const JSig.of([JType.string], returns: JType.boolean).descriptor,
        '(Ljava/lang/String;)Z',
      );
    });

    test('is const-constructible', () {
      const add = JSig.of([JType.int_, JType.int_], returns: JType.int_);
      expect(
        identical(
          add,
          const JSig.of([JType.int_, JType.int_], returns: JType.int_),
        ),
        isTrue,
      );
    });

    test('ctor returns void', () {
      expect(
        const JSig.ctor([JType.string]).descriptor,
        '(Ljava/lang/String;)V',
      );
      expect(const JSig.ctor([]).descriptor, '()V');
    });

    test('a void parameter is rejected', () {
      expect(
        () => const JSig.of([JType.void_]).descriptor,
        throwsA(isA<JniError>()),
      );
    });

    test('round-trips through the existing parser', () {
      const sig = JSig.of([JType.int_, JType.string], returns: JType.boolean);
      final parsed = JniSignature.parse(sig.descriptor);
      expect(parsed.parameters, ['I', 'Ljava/lang/String;']);
      expect(parsed.returnType, 'Z');
    });

    test('equality is by descriptor', () {
      expect(
        const JSig.of([JType.int_]),
        const JSig.of([JType.int_], returns: JType.void_),
      );
    });
  });

  group('jsig', () {
    test('the shapes from this package\'s own call sites', () {
      expect(jsig('String greet()'), '()Ljava/lang/String;');
      expect(jsig('int add(int, int)'), '(II)I');
      expect(jsig('void (String)'), '(Ljava/lang/String;)V');
      expect(jsig('(String, int)'), '(Ljava/lang/String;I)V');
      expect(
        jsig('String join(String[])'),
        '([Ljava/lang/String;)Ljava/lang/String;',
      );
      expect(jsig('int sumNested(int[][])'), '([[I)I');
      expect(
        jsig('Object put(Object, Object)'),
        '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;',
      );
      expect(
        jsig(
          'String mixed(boolean, byte, char, short, int, long, float, '
          'double)',
        ),
        '(ZBCSIJFD)Ljava/lang/String;',
      );
      expect(jsig('void read(java.io.Reader)'), '(Ljava/io/Reader;)V');
    });

    test('parameter names are ignored', () {
      expect(jsig('int add(int a, int b)'), '(II)I');
      expect(
        jsig('void set(String name, int value)'),
        '(Ljava/lang/String;I)V',
      );
    });

    test('modifiers and annotations are ignored', () {
      expect(jsig('public static int add(int, int)'), '(II)I');
      expect(jsig('private final synchronized void run()'), '()V');
      expect(jsig('@Deprecated String greet()'), '()Ljava/lang/String;');
      expect(jsig('void set(@NotNull String s)'), '(Ljava/lang/String;)V');
    });

    test('a throws clause is ignored', () {
      expect(jsig('void write(byte[]) throws java.io.IOException'), '([B)V');
    });

    test('generics are erased', () {
      expect(
        jsig('java.util.List<String> subList(int, int)'),
        '(II)Ljava/util/List;',
      );
      expect(
        jsig('void addAll(java.util.List<? extends Number>)'),
        '(Ljava/util/List;)V',
      );
    });

    test('varargs become an array', () {
      expect(
        jsig('String format(String, Object...)'),
        '(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;',
      );
    });

    test('whitespace is not significant', () {
      expect(jsig('  int   add( int , int )  '), '(II)I');
      expect(jsig('String greet( )'), '()Ljava/lang/String;');
    });

    test('rejects nonsense with a message naming the input', () {
      expect(
        () => jsig('int add'),
        throwsA(
          isA<JniError>().having((e) => e.message, 'message', contains('"(")')),
        ),
      );
      expect(() => jsig('int add(int, int'), throwsA(isA<JniError>()));
      expect(() => jsig('int add(void)'), throwsA(isA<JniError>()));
      expect(() => jsig('int not a name(int)'), throwsA(isA<JniError>()));
    });
  });

  group('jtype', () {
    test('produces a type descriptor', () {
      expect(jtype('int'), 'I');
      expect(jtype('String'), 'Ljava/lang/String;');
      expect(jtype('String[]'), '[Ljava/lang/String;');
      expect(jtype('java.util.Map'), 'Ljava/util/Map;');
    });
  });

  group('JavaMethod.parse', () {
    test('keeps the name when one is given', () {
      final method = JavaMethod.parse('int add(int, int)');
      expect(method.name, 'add');
      expect(method.descriptor, '(II)I');
      expect(method.toString(), 'add(II)I');
    });

    test('has no name for a constructor', () {
      expect(JavaMethod.parse('(String)').name, isNull);
      expect(JavaMethod.parse('void (String)').name, isNull);
      expect(
        JavaMethod.parse('(String)').toString(),
        '<init>(Ljava/lang/String;)V',
      );
    });

    test('caches by declaration, so a loop does not re-parse', () {
      final first = JavaMethod.parse('int add(int, int)');
      final second = JavaMethod.parse('int add(int, int)');
      expect(identical(first, second), isTrue);
    });
  });

  group('JavaField.parse', () {
    test('splits a type and a name', () {
      final field = JavaField.parse('int count');
      expect(field.name, 'count');
      expect(field.descriptor, 'I');
    });

    test('ignores modifiers and erases generics', () {
      expect(JavaField.parse('public static final String NAME').name, 'NAME');
      expect(
        JavaField.parse('public static final String NAME').descriptor,
        'Ljava/lang/String;',
      );
      expect(
        JavaField.parse('java.util.List<String> items').descriptor,
        'Ljava/util/List;',
      );
      expect(JavaField.parse('int[] values').descriptor, '[I');
    });

    test('rejects a bare type or a void field', () {
      expect(() => JavaField.parse('int'), throwsA(isA<JniError>()));
      expect(() => JavaField.parse('void nothing'), throwsA(isA<JniError>()));
    });

    test('caches by declaration', () {
      expect(
        identical(JavaField.parse('int count'), JavaField.parse('int count')),
        isTrue,
      );
    });
  });
}
