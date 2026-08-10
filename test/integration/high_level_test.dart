@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;

  setUpAll(() => jvm = testJvm);

  group('JavaObject basics', () {
    test('javaToString delegates to Java toString()', () {
      final integerClass = JavaClass.forName(jvm, 'java.lang.Integer');
      addTearDown(integerClass.release);

      final value =
          integerClass.callStatic('valueOf', '(I)Ljava/lang/Integer;', [42])
              as JavaObject;
      addTearDown(value.release);

      expect(value.javaToString(), '42');
    });

    test('javaEquals uses equals(), not reference identity', () {
      final integerClass = JavaClass.forName(jvm, 'java.lang.Integer');
      addTearDown(integerClass.release);

      // 1000 is outside the Integer cache, so these are distinct objects.
      final a =
          integerClass.callStatic('valueOf', '(I)Ljava/lang/Integer;', [1000])
              as JavaObject;
      final b =
          integerClass.callStatic('valueOf', '(I)Ljava/lang/Integer;', [1000])
              as JavaObject;
      addTearDown(a.release);
      addTearDown(b.release);

      expect(a.javaEquals(b), isTrue, reason: 'equal by value');
      expect(
        a.ref.isSameObject(b.ref),
        isFalse,
        reason: 'but distinct objects',
      );
    });

    test('type resolves the runtime class lazily', () {
      final object = fixturesInstance();
      expect(object.type.name, 'com.nfeflash.example.Fixtures');
    });

    test('toString describes the handle', () {
      expect(fixturesInstance().toString(), startsWith('JavaObject(JavaRef('));
    });

    test('a null JavaObject reports isNull', () {
      final object = fixturesInstance();
      final nullValue =
          object.getField('objectField', JniType.object) as JavaObject;
      addTearDown(nullValue.release);

      expect(nullValue.isNull, isTrue);
      expect(nullValue.toString(), 'JavaObject(null)');
    });
  });

  group('working with the JDK', () {
    test('java.lang.Math statics', () {
      final math = JavaClass.forName(jvm, 'java.lang.Math');
      addTearDown(math.release);

      expect(math.callStatic('abs', '(I)I', [-5]), 5);
      expect(math.callStatic('max', '(JJ)J', [10, 20]), 20);
      expect(math.callStatic('sqrt', '(D)D', [16.0]), 4.0);
      expect(
        math.getStaticField('PI', JniType.double_),
        closeTo(3.14159, 1e-5),
      );
    });

    test('java.lang.String instance methods', () {
      final stringClass = JavaClass.forName(jvm, 'java.lang.String');
      addTearDown(stringClass.release);

      final text = JavaObject(jvm, autoRelease(jvm.newString('Hello, World')));

      expect(text.call('length', '()I'), 12);
      expect(text.call('toUpperCase', '()Ljava/lang/String;'), 'HELLO, WORLD');
      expect(
        text.call('substring', '(II)Ljava/lang/String;', [7, 12]),
        'World',
      );
      expect(
        text.call('contains', '(Ljava/lang/CharSequence;)Z', ['World']),
        isTrue,
      );
      expect(text.call('indexOf', '(Ljava/lang/String;)I', ['World']), 7);
      expect(
        text.call(
          'replace',
          '(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)'
              'Ljava/lang/String;',
          ['World', 'Dart'],
        ),
        'Hello, Dart',
      );
    });

    test('java.util.ArrayList through its interface methods', () {
      final listClass = JavaClass.forName(jvm, 'java.util.ArrayList');
      addTearDown(listClass.release);

      final list = listClass.newInstance();
      addTearDown(list.release);

      expect(list.call('add', '(Ljava/lang/Object;)Z', ['a']), isTrue);
      expect(list.call('add', '(Ljava/lang/Object;)Z', ['b']), isTrue);
      expect(list.call('size', '()I'), 2);
      expect(list.call('isEmpty', '()Z'), isFalse);

      final first =
          list.call('get', '(I)Ljava/lang/Object;', [0]) as JavaObject;
      addTearDown(first.release);
      expect(first.javaToString(), 'a');

      expect(list.javaToString(), '[a, b]');
    });

    test('java.lang.System properties', () {
      final system = JavaClass.forName(jvm, 'java.lang.System');
      addTearDown(system.release);

      final version = system.callStatic(
        'getProperty',
        '(Ljava/lang/String;)Ljava/lang/String;',
        ['java.version'],
      );

      expect(version, isA<String>());
      expect(version as String, isNotEmpty);
    });

    test('a StringBuilder chain returns the same object', () {
      final builderClass = JavaClass.forName(jvm, 'java.lang.StringBuilder');
      addTearDown(builderClass.release);

      final builder = builderClass.newInstance();
      addTearDown(builder.release);

      // append returns `this`, so the result is the same underlying object.
      final returned =
          builder.call(
                'append',
                '(Ljava/lang/String;)Ljava/lang/StringBuilder;',
                ['ab'],
              )
              as JavaObject;
      addTearDown(returned.release);

      expect(returned.ref.isSameObject(builder.ref), isTrue);
      expect(builder.javaToString(), 'ab');
    });
  });

  group('reference hygiene', () {
    test('a String return does not leak a reference to the caller', () {
      // String returns are converted and released internally, so a tight loop
      // must not exhaust the local reference table.
      final fixtures = fixturesClass();

      for (var i = 0; i < 5000; i++) {
        expect(
          fixtures.callStatic(
            'echoString',
            '(Ljava/lang/String;)Ljava/lang/String;',
            ['value $i'],
          ),
          'value $i',
        );
      }
    });

    test('object returns are owned by the caller and released explicitly', () {
      final fixtures = fixturesClass();

      jvm.localFrame(() {
        for (var i = 0; i < 500; i++) {
          final echoed =
              fixtures.callStatic(
                    'staticEchoObject',
                    '(Ljava/lang/Object;)Ljava/lang/Object;',
                    ['x'],
                  )
                  as JavaObject;
          echoed.release();
        }
      });

      expect(fixtures.callStatic('staticSum', '(II)I', [1, 1]), 2);
    });
  });

  group('signature-driven dispatch', () {
    test(
      'the same method name with different signatures resolves correctly',
      () {
        final math = JavaClass.forName(jvm, 'java.lang.Math');
        addTearDown(math.release);

        // Math.abs is overloaded for int, long, float and double: each must pick
        // the matching JNI accessor, or the result comes back mangled.
        expect(math.callStatic('abs', '(I)I', [-5]), 5);
        expect(math.callStatic('abs', '(J)J', [-5]), 5);
        expect(math.callStatic('abs', '(F)F', [-5.5]), 5.5);
        expect(math.callStatic('abs', '(D)D', [-5.5]), 5.5);

        expect(math.callStatic('abs', '(I)I', [-5]), isA<int>());
        expect(math.callStatic('abs', '(D)D', [-5.5]), isA<double>());
      },
    );

    test('an invalid signature is rejected before any JNI call', () {
      final math = JavaClass.forName(jvm, 'java.lang.Math');
      addTearDown(math.release);

      expect(
        () => math.callStatic('abs', 'not-a-signature', [1]),
        throwsA(isA<JniError>()),
      );
    });
  });
}
