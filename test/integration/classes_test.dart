@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;

  setUpAll(() => jvm = testJvm);

  group('findClass', () {
    test('accepts a dotted name', () {
      final clazz = autoRelease(jvm.findClass('java.lang.String'));
      expect(clazz.isNull, isFalse);
    });

    test('accepts a JNI (slashed) name', () {
      final clazz = autoRelease(jvm.findClass('java/lang/String'));
      expect(clazz.isNull, isFalse);
    });

    test('both forms resolve to the same class', () {
      final dotted = autoRelease(jvm.findClass('java.lang.String'));
      final slashed = autoRelease(jvm.findClass('java/lang/String'));

      expect(dotted.isSameObject(slashed), isTrue);
    });

    test('finds a class from the jar on the class path', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));
      expect(clazz.isNull, isFalse);
    });

    test('finds a nested class with the \$ separator', () {
      final clazz = autoRelease(
        jvm.findClass('com.nfeflash.example.Fixtures\$Nested'),
      );

      final method = jvm.staticMethodId(clazz, 'hello', '()Ljava/lang/String;');
      final result = autoRelease(jvm.callStaticObjectMethod(clazz, method));

      expect(jvm.stringFrom(result), 'from Nested');
    });

    test('an unknown class raises a lookup error naming it', () {
      expect(
        () => jvm.findClass('com.example.DefinitelyMissing'),
        throwsA(
          isA<JniLookupError>()
              .having((e) => e.kind, 'kind', 'class')
              .having((e) => e.name, 'name', 'com.example.DefinitelyMissing'),
        ),
      );
    });

    test('a failed lookup leaves no pending exception behind', () {
      // NoClassDefFoundError must be cleared, or the next unrelated call fails
      // with a confusing error inherited from this one.
      expect(
        () => jvm.findClass('com.example.Missing'),
        throwsA(isA<JniLookupError>()),
      );

      final clazz = fixturesClass();
      expect(clazz.callStatic('staticSum', '(II)I', [1, 1]), 2);
    });
  });

  group('class relationships', () {
    test('getObjectClass returns the runtime class', () {
      final string = autoRelease(jvm.newString('hello'));
      final clazz = autoRelease(jvm.getObjectClass(string));
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));

      expect(clazz.isSameObject(stringClass), isTrue);
    });

    test('getSuperclass walks up the hierarchy', () {
      final custom = autoRelease(
        jvm.findClass('com.nfeflash.example.Fixtures\$FixtureException'),
      );
      final runtime = autoRelease(jvm.findClass('java.lang.RuntimeException'));

      expect(
        autoRelease(jvm.getSuperclass(custom)).isSameObject(runtime),
        isTrue,
      );
    });

    test('Object has no superclass', () {
      final object = autoRelease(jvm.findClass('java.lang.Object'));
      expect(autoRelease(jvm.getSuperclass(object)).isNull, isTrue);
    });

    test('isInstanceOf implements instanceof', () {
      final string = autoRelease(jvm.newString('hello'));
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final objectClass = autoRelease(jvm.findClass('java.lang.Object'));
      final integerClass = autoRelease(jvm.findClass('java.lang.Integer'));

      expect(jvm.isInstanceOf(string, stringClass), isTrue);
      expect(jvm.isInstanceOf(string, objectClass), isTrue);
      expect(jvm.isInstanceOf(string, integerClass), isFalse);
    });

    test('isAssignableFrom checks the direction of the relationship', () {
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final objectClass = autoRelease(jvm.findClass('java.lang.Object'));

      expect(
        jvm.isAssignableFrom(stringClass, objectClass),
        isTrue,
        reason: 'a String is usable as an Object',
      );
      expect(
        jvm.isAssignableFrom(objectClass, stringClass),
        isFalse,
        reason: 'an Object is not usable as a String',
      );
    });

    test('JavaClass.superclass wraps the same relationship', () {
      final custom = JavaClass.forName(
        jvm,
        'com.nfeflash.example.Fixtures\$FixtureException',
      );
      addTearDown(custom.release);

      final parent = custom.superclass;
      addTearDown(() => parent?.release());

      expect(parent, isNotNull);
      expect(parent!.name, 'java.lang.RuntimeException');

      final object = JavaClass.forName(jvm, 'java.lang.Object');
      addTearDown(object.release);
      expect(object.superclass, isNull);
    });

    test('JavaClass.isAssignableFrom', () {
      final object = JavaClass.forName(jvm, 'java.lang.Object');
      final string = JavaClass.forName(jvm, 'java.lang.String');
      addTearDown(object.release);
      addTearDown(string.release);

      expect(object.isAssignableFrom(string), isTrue);
      expect(string.isAssignableFrom(object), isFalse);
    });
  });

  group('member resolution', () {
    test('resolves instance and static methods, fields and constructors', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));

      expect(jvm.methodId(clazz, '<init>', '()V'), isNotNull);
      expect(jvm.methodId(clazz, 'sum', '(II)I'), isNotNull);
      expect(jvm.staticMethodId(clazz, 'staticSum', '(II)I'), isNotNull);
      expect(jvm.fieldId(clazz, 'intField', 'I'), isNotNull);
      expect(jvm.staticFieldId(clazz, 'staticIntField', 'I'), isNotNull);
    });

    test('an unknown member names the descriptor that failed', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));

      expect(
        () => jvm.methodId(clazz, 'noSuchMethod', '()V'),
        throwsA(
          isA<JniLookupError>()
              .having((e) => e.kind, 'kind', 'method')
              .having((e) => e.name, 'name', 'noSuchMethod')
              .having((e) => e.signature, 'signature', '()V'),
        ),
      );

      expect(
        () => jvm.staticMethodId(clazz, 'nope', '()V'),
        throwsA(
          isA<JniLookupError>().having((e) => e.kind, 'kind', 'static method'),
        ),
      );
      expect(
        () => jvm.fieldId(clazz, 'nope', 'I'),
        throwsA(isA<JniLookupError>().having((e) => e.kind, 'kind', 'field')),
      );
      expect(
        () => jvm.staticFieldId(clazz, 'nope', 'I'),
        throwsA(
          isA<JniLookupError>().having((e) => e.kind, 'kind', 'static field'),
        ),
      );
    });

    test('the wrong signature is a lookup failure, not a silent mismatch', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));

      // `sum` is (II)I; asking for (I)I must fail rather than bind loosely.
      expect(
        () => jvm.methodId(clazz, 'sum', '(I)I'),
        throwsA(isA<JniLookupError>()),
      );
    });

    test('a failed member lookup leaves no pending exception behind', () {
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));

      expect(
        () => jvm.methodId(clazz, 'nope', '()V'),
        throwsA(isA<JniLookupError>()),
      );

      final method = jvm.staticMethodId(clazz, 'staticSum', '(II)I');
      expect(
        jvm.callStaticIntMethod(clazz, method, [
          JValue.fromInt(3),
          JValue.fromInt(4),
        ]),
        7,
      );
    });
  });

  group('JavaClass.forName', () {
    test('records the dotted name', () {
      final clazz = JavaClass.forName(jvm, 'java/lang/String');
      addTearDown(clazz.release);

      expect(clazz.name, 'java.lang.String');
      expect(clazz.toString(), 'JavaClass(java.lang.String)');
    });

    test('can hold a global reference', () {
      final clazz = JavaClass.forName(
        jvm,
        'com.nfeflash.example.Fixtures',
        global: true,
      );
      addTearDown(clazz.release);

      expect(clazz.ref.kind, JavaRefKind.global);
      expect(clazz.callStatic('staticSum', '(II)I', [1, 2]), 3);
    });
  });
}
