@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

void main() {
  group('JniType', () {
    test('converts class names between dotted and JNI form', () {
      expect(JniType.classNameToJni('java.lang.String'), 'java/lang/String');
      expect(JniType.classNameToJni('java/lang/String'), 'java/lang/String');
      expect(JniType.classNameToDotted('java/lang/String'), 'java.lang.String');
      expect(
        JniType.classNameToJni('com.example.Outer\$Inner'),
        'com/example/Outer\$Inner',
      );
    });

    test('builds object and array descriptors', () {
      expect(JniType.objectOf('java.lang.String'), 'Ljava/lang/String;');
      expect(JniType.objectOf('java/lang/String'), 'Ljava/lang/String;');
      expect(JniType.arrayOf(JniType.int_), '[I');
      expect(JniType.arrayOf(JniType.arrayOf(JniType.double_)), '[[D');
      expect(JniType.arrayOf(JniType.string), '[Ljava/lang/String;');
    });

    test('classifies descriptors', () {
      for (final primitive in ['Z', 'B', 'C', 'S', 'I', 'J', 'F', 'D']) {
        expect(JniType.isPrimitive(primitive), isTrue, reason: primitive);
        expect(JniType.isReference(primitive), isFalse, reason: primitive);
      }

      expect(JniType.isPrimitive('V'), isFalse, reason: 'void is not a value');
      expect(JniType.isPrimitive('Ljava/lang/String;'), isFalse);
      expect(JniType.isReference('Ljava/lang/String;'), isTrue);
      expect(JniType.isReference('[I'), isTrue);
    });
  });

  group('JniSignature.parse', () {
    test('splits parameters from the return type', () {
      final signature = JniSignature.parse('(ILjava/lang/String;)Z');

      expect(signature.parameters, ['I', 'Ljava/lang/String;']);
      expect(signature.returnType, 'Z');
      expect(signature.parameterCount, 2);
      expect(signature.descriptor, '(ILjava/lang/String;)Z');
    });

    test('handles a no-argument void method', () {
      final signature = JniSignature.parse('()V');

      expect(signature.parameters, isEmpty);
      expect(signature.returnType, 'V');
      expect(signature.parameterCount, 0);
    });

    test('handles every primitive parameter in one signature', () {
      final signature = JniSignature.parse('(ZBCSIJFD)Ljava/lang/String;');

      expect(signature.parameters, ['Z', 'B', 'C', 'S', 'I', 'J', 'F', 'D']);
      expect(signature.returnType, 'Ljava/lang/String;');
    });

    test('handles arrays, including arrays of arrays and of objects', () {
      final signature = JniSignature.parse(
        '([I[[D[Ljava/lang/String;)[Ljava/lang/Object;',
      );

      expect(signature.parameters, ['[I', '[[D', '[Ljava/lang/String;']);
      expect(signature.returnType, '[Ljava/lang/Object;');
    });

    test('handles nested class names', () {
      final signature = JniSignature.parse(
        '(Lcom/example/Outer\$Inner;)Lcom/a/B\$C;',
      );

      expect(signature.parameters, ['Lcom/example/Outer\$Inner;']);
      expect(signature.returnType, 'Lcom/a/B\$C;');
    });

    test('rejects malformed signatures with an explanatory message', () {
      void expectRejected(String descriptor, String reason) {
        expect(
          () => JniSignature.parse(descriptor),
          throwsA(
            isA<JniError>().having(
              (e) => e.message,
              'message',
              contains(reason),
            ),
          ),
          reason: descriptor,
        );
      }

      expectRejected('II)I', 'must start with');
      expectRejected('(II', 'missing ")"');
      expectRejected('(II)', 'missing return type');
      expectRejected('(Ljava/lang/String)V', 'unterminated object type');
      expectRejected('(L;)V', 'empty class name');
      expectRejected('(Q)V', 'unknown type');
      expectRejected('(I)II', 'trailing return type');
      expectRejected('([)V', 'array with no element type');
      expectRejected('([V)V', 'void array');
      expectRejected('(V)V', 'only valid as a bare return type');
      expectRejected('(I)[V', 'void array');
    });
  });

  group('JniSignature.of', () {
    test('builds a descriptor from parts', () {
      expect(
        JniSignature.of([
          JniType.int_,
          JniType.string,
        ], returns: JniType.boolean).descriptor,
        '(ILjava/lang/String;)Z',
      );
      expect(JniSignature.of([]).descriptor, '()V');
      expect(
        JniSignature.of([
          JniType.arrayOf(JniType.int_),
        ], returns: JniType.int_).descriptor,
        '([I)I',
      );
    });

    test('validates while building, so typos surface at the call site', () {
      expect(
        () => JniSignature.of(['Ljava/lang/String']),
        throwsA(isA<JniError>()),
      );
    });

    test('builds constructor signatures', () {
      expect(JniSignature.constructor().descriptor, '()V');
      expect(
        JniSignature.constructor([JniType.string, JniType.int_]).descriptor,
        '(Ljava/lang/String;I)V',
      );
    });
  });

  group('JniSignature value semantics', () {
    test('equality and hashCode follow the descriptor', () {
      final a = JniSignature.parse('(II)I');
      final b = JniSignature.of([
        JniType.int_,
        JniType.int_,
      ], returns: JniType.int_);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(JniSignature.parse('(I)I')));
    });

    test('toString is the descriptor', () {
      expect(JniSignature.parse('(II)I').toString(), '(II)I');
    });

    test('parameters are unmodifiable', () {
      final signature = JniSignature.parse('(II)I');
      expect(() => signature.parameters.add('I'), throwsUnsupportedError);
    });
  });
}
