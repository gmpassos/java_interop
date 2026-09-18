@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;
  late JavaClass fixtures;

  setUpAll(() => jvm = testJvm);
  setUp(() => fixtures = fixturesClass());

  JavaObject instance() => fixturesInstance(fixtures);

  group('instance methods, one per JNI return type', () {
    test('void', () {
      final object = instance();
      expect(object.call('voidMethod', '()V'), isNull);
      expect(
        object.getField('stringField', JniType.string),
        'voidMethod called',
      );
    });

    test('boolean', () {
      expect(instance().call('negate', '(Z)Z', [true]), isFalse);
      expect(instance().call('negate', '(Z)Z', [false]), isTrue);
    });

    test('byte keeps its sign', () {
      // jbyte is a *signed* char; reading it through an unsigned type would
      // turn -128 into 128.
      expect(instance().call('byteIdentity', '(B)B', [-128]), -128);
      expect(instance().call('byteIdentity', '(B)B', [127]), 127);
      expect(instance().call('byteIdentity', '(B)B', [-1]), -1);
    });

    test('char is unsigned UTF-16', () {
      expect(
        instance().call('upperCase', '(C)C', ['a'.codeUnitAt(0)]),
        'A'.codeUnitAt(0),
      );
      // U+00E7 ç -> U+00C7 Ç, above the signed-byte range.
      expect(instance().call('upperCase', '(C)C', [0x00E7]), 0x00C7);
    });

    test('short keeps its sign', () {
      expect(instance().call('shortIdentity', '(S)S', [-32768]), -32768);
      expect(instance().call('shortIdentity', '(S)S', [32767]), 32767);
    });

    test('int', () {
      expect(instance().call('sum', '(II)I', [2, 40]), 42);
      expect(instance().call('sum', '(II)I', [-1, 1]), 0);
    });

    test('long carries the full 64-bit range', () {
      expect(
        instance().call('longIdentity', '(J)J', [9223372036854775807]),
        9223372036854775807,
      );
      expect(
        instance().call('longIdentity', '(J)J', [-9223372036854775808]),
        -9223372036854775808,
      );
      expect(instance().call('longIdentity', '(J)J', [1 << 40]), 1 << 40);
    });

    test('float', () {
      expect(instance().call('halveFloat', '(F)F', [3.5]), 1.75);
      expect(instance().call('halveFloat', '(F)F', [-1.0]), -0.5);
    });

    test('double keeps full precision', () {
      expect(
        instance().call('halveDouble', '(D)D', [2.718281828459045]),
        1.3591409142295225,
      );
    });

    test('object (String)', () {
      expect(
        instance().call(
          'concat',
          '(Ljava/lang/String;Ljava/lang/String;)'
              'Ljava/lang/String;',
          ['a', 'b'],
        ),
        'ab',
      );
    });

    test('a null return round-trips as null', () {
      expect(instance().call('nullString', '()Ljava/lang/String;'), isNull);
    });

    test('every primitive at once, to check jvalue packing order', () {
      // If any argument were written into the wrong slot or the wrong width,
      // the fields would come back permuted or corrupted rather than fail.
      final result = instance().call('mixed', '(ZBCSIJFD)Ljava/lang/String;', [
        true,
        -128,
        0x0041,
        -32768,
        2147483647,
        9223372036854775807,
        1.5,
        2.5,
      ]);

      expect(
        result,
        'true|-128|A|-32768|2147483647|9223372036854775807|1.5|2.5',
      );
    });
  });

  group('static methods, one per JNI return type', () {
    test('void', () {
      fixtures.callStatic('resetStatics', '()V');
      expect(fixtures.callStatic('staticVoidMethod', '()V'), isNull);
      expect(
        fixtures.getStaticField('staticStringField', JniType.string),
        'staticVoidMethod called',
      );
      fixtures.callStatic('resetStatics', '()V');
    });

    test('boolean', () {
      expect(fixtures.callStatic('staticNegate', '(Z)Z', [true]), isFalse);
    });

    test('byte', () {
      expect(fixtures.callStatic('staticByteIdentity', '(B)B', [-128]), -128);
    });

    test('char', () {
      expect(fixtures.callStatic('staticUpperCase', '(C)C', [0x00E7]), 0x00C7);
    });

    test('short', () {
      expect(
        fixtures.callStatic('staticShortIdentity', '(S)S', [-32768]),
        -32768,
      );
    });

    test('int', () {
      expect(fixtures.callStatic('staticSum', '(II)I', [2, 40]), 42);
    });

    test('long', () {
      expect(
        fixtures.callStatic('staticLongIdentity', '(J)J', [
          -9223372036854775808,
        ]),
        -9223372036854775808,
      );
    });

    test('float', () {
      expect(fixtures.callStatic('staticHalveFloat', '(F)F', [3.5]), 1.75);
    });

    test('double', () {
      expect(fixtures.callStatic('staticHalveDouble', '(D)D', [5.0]), 2.5);
    });

    test('object (String)', () {
      expect(
        fixtures.callStatic(
          'staticConcat',
          '(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
          ['x', 'y'],
        ),
        'xy',
      );
    });
  });

  group('argument handling', () {
    test('a Dart String becomes a java.lang.String automatically', () {
      expect(
        fixtures.callStatic(
          'echoString',
          '(Ljava/lang/String;)Ljava/lang/String;',
          ['hello'],
        ),
        'hello',
      );
    });

    test('null is passed through as a Java null', () {
      expect(
        fixtures.callStatic(
          'echoString',
          '(Ljava/lang/String;)Ljava/lang/String;',
          [null],
        ),
        isNull,
      );
    });

    test('a JavaObject can be passed as an argument', () {
      final object = instance();
      final echoed =
          fixtures.callStatic(
                'staticEchoObject',
                '(Ljava/lang/Object;)Ljava/lang/Object;',
                [object],
              )
              as JavaObject;
      addTearDown(echoed.release);

      expect(echoed.ref.isSameObject(object.ref), isTrue);
    });

    test('an int is accepted where a float or double is declared', () {
      expect(fixtures.callStatic('staticHalveFloat', '(F)F', [4]), 2.0);
      expect(fixtures.callStatic('staticHalveDouble', '(D)D', [4]), 2.0);
    });

    test('the wrong argument count is rejected before reaching the VM', () {
      expect(
        () => fixtures.callStatic('staticSum', '(II)I', [1]),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('expects 2'),
          ),
        ),
      );
      expect(
        () => fixtures.callStatic('staticSum', '(II)I', [1, 2, 3]),
        throwsA(isA<JniError>()),
      );
    });

    test('a mistyped argument is rejected with the parameter descriptor', () {
      expect(
        () => fixtures.callStatic('staticSum', '(II)I', ['a', 2]),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('expected an int'),
          ),
        ),
      );
    });

    test('an unsupported Dart type is rejected for a reference parameter', () {
      expect(
        () => fixtures.callStatic(
          'staticEchoObject',
          '(Ljava/lang/Object;)Ljava/lang/Object;',
          [DateTime(2020)],
        ),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('cannot pass'),
          ),
        ),
      );
    });
  });

  group('constructors', () {
    test('the no-arg constructor', () {
      final object = instance();
      expect(object.call('getLabel', '()Ljava/lang/String;'), 'default');
      expect(object.call('getNumber', '()I'), 0);
    });

    test('an overloaded constructor is picked by signature', () {
      final one = fixtures.newInstance('(Ljava/lang/String;)V', ['tagged']);
      addTearDown(one.release);
      expect(one.call('getLabel', '()Ljava/lang/String;'), 'tagged');
      expect(one.call('getNumber', '()I'), 0);

      final two = fixtures.newInstance('(Ljava/lang/String;I)V', ['tagged', 7]);
      addTearDown(two.release);
      expect(two.call('getLabel', '()Ljava/lang/String;'), 'tagged');
      expect(two.call('getNumber', '()I'), 7);
    });

    test('a constructor signature that does not exist is a lookup error', () {
      expect(
        () => fixtures.newInstance('(D)V', [1.0]),
        throwsA(isA<JniLookupError>()),
      );
    });
  });

  group('typed helpers', () {
    test('callStaticAs returns the requested type', () {
      expect(fixtures.callStaticAs<int>('staticSum', '(II)I', [1, 2]), 3);
      expect(
        fixtures.callStaticAs<String>(
          'staticConcat',
          '(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
          ['a', 'b'],
        ),
        'ab',
      );
    });

    test('callAs returns the requested type', () {
      expect(instance().callAs<int>('sum', '(II)I', [20, 22]), 42);
    });

    test('a type mismatch is reported, naming the member', () {
      expect(
        () => fixtures.callStaticAs<String>('staticSum', '(II)I', [1, 2]),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('staticSum returned int'),
          ),
        ),
      );
    });
  });

  group('raw call API', () {
    test('mirrors JNI one-to-one for callers that need it', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));
      final method = jvm.staticMethodId(clazz, 'staticSum', '(II)I');

      expect(
        jvm.callStaticIntMethod(clazz, method, [
          JValue.fromInt(20),
          JValue.fromInt(22),
        ]),
        42,
      );
    });

    test('newObject + callObjectMethod round-trip', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));
      final constructor = jvm.methodId(
        clazz,
        '<init>',
        '(Ljava/lang/String;)V',
      );
      final label = autoRelease(jvm.newString('Raw'));

      final instance = autoRelease(
        jvm.newObject(clazz, constructor, [JValue.fromPointer(label.pointer)]),
      );
      final getLabel = jvm.methodId(clazz, 'getLabel', '()Ljava/lang/String;');
      final result = autoRelease(jvm.callObjectMethod(instance, getLabel));

      expect(jvm.stringFrom(result), 'Raw');
    });

    /// `callByReturnType` is the dispatcher the signature-driven layer sits on:
    /// it picks the JNI accessor from the return descriptor, which is the whole
    /// reason `callIntMethod` is never called for a method returning `long`. A
    /// descriptor it cannot place has to fail here, before the call.
    test('callByReturnType dispatches on the descriptor, and refuses junk', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));
      final method = jvm.staticMethodId(clazz, 'staticSum', '(II)I');
      final args = [JValue.fromInt(1), JValue.fromInt(2)];

      expect(
        jvm.callByReturnType(JniType.int_, clazz, method, args, static: true),
        3,
      );
      expect(
        () => jvm.callByReturnType('Q', clazz, method, args, static: true),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('unknown return descriptor'),
          ),
        ),
      );
    });
  });
}
