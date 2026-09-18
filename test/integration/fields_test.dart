@TestOn('vm')
library;

import 'dart:ffi';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late JavaClass fixtures;

  setUp(() {
    fixtures = fixturesClass();
    // Static fields are process-global state shared by every test in this
    // suite, so they are restored before each one.
    fixtures.callStatic('resetStatics', '()V');
  });

  group('instance fields: read', () {
    late JavaObject object;
    setUp(() => object = fixturesInstance(fixtures));

    test('boolean', () {
      expect(object.getField('booleanField', JniType.boolean), isTrue);
    });

    test('byte keeps its sign', () {
      expect(object.getField('byteField', JniType.byte), -128);
    });

    test('char is unsigned', () {
      expect(object.getField('charField', JniType.char), 0x00E7);
    });

    test('short keeps its sign', () {
      expect(object.getField('shortField', JniType.short), -32768);
    });

    test('int', () {
      expect(object.getField('intField', JniType.int_), 2147483647);
    });

    test('long', () {
      expect(object.getField('longField', JniType.long), 9223372036854775807);
    });

    test('float', () {
      expect(object.getField('floatField', JniType.float), 3.5);
    });

    test('double keeps full precision', () {
      expect(
        object.getField('doubleField', JniType.double_),
        2.718281828459045,
      );
    });

    test('String comes back as a Dart string', () {
      expect(object.getField('stringField', JniType.string), 'initial');
    });

    test('a null object field is null', () {
      final value = object.getField('objectField', JniType.object);
      expect(value, isA<JavaObject>());
      expect((value as JavaObject).isNull, isTrue);
    });
  });

  group('instance fields: write', () {
    late JavaObject object;
    setUp(() => object = fixturesInstance(fixtures));

    test('boolean', () {
      object.setField('booleanField', JniType.boolean, false);
      expect(object.getField('booleanField', JniType.boolean), isFalse);
    });

    test('byte', () {
      object.setField('byteField', JniType.byte, 127);
      expect(object.getField('byteField', JniType.byte), 127);
    });

    test('char', () {
      object.setField('charField', JniType.char, 0x4E2D); // 中
      expect(object.getField('charField', JniType.char), 0x4E2D);
    });

    test('short', () {
      object.setField('shortField', JniType.short, 32767);
      expect(object.getField('shortField', JniType.short), 32767);
    });

    test('int', () {
      object.setField('intField', JniType.int_, -2147483648);
      expect(object.getField('intField', JniType.int_), -2147483648);
    });

    test('long', () {
      object.setField('longField', JniType.long, -9223372036854775808);
      expect(object.getField('longField', JniType.long), -9223372036854775808);
    });

    test('float', () {
      object.setField('floatField', JniType.float, -0.25);
      expect(object.getField('floatField', JniType.float), -0.25);
    });

    test('double', () {
      object.setField('doubleField', JniType.double_, 1.5);
      expect(object.getField('doubleField', JniType.double_), 1.5);
    });

    test('a Dart String is converted automatically', () {
      object.setField('stringField', JniType.string, 'written');
      expect(object.getField('stringField', JniType.string), 'written');
    });

    test('a String field can be set to null', () {
      object.setField('stringField', JniType.string, null);
      expect(object.getField('stringField', JniType.string), isNull);
    });

    test('an object field accepts a JavaObject', () {
      final other = fixturesInstance(fixtures);
      object.setField('objectField', JniType.object, other);

      final read = object.getField('objectField', JniType.object) as JavaObject;
      addTearDown(read.release);
      expect(read.ref.isSameObject(other.ref), isTrue);
    });

    test('an int is accepted where a float or double is declared', () {
      object.setField('floatField', JniType.float, 2);
      expect(object.getField('floatField', JniType.float), 2.0);

      object.setField('doubleField', JniType.double_, 3);
      expect(object.getField('doubleField', JniType.double_), 3.0);
    });

    test('a mistyped value is rejected, naming the field descriptor', () {
      expect(
        () => object.setField('intField', JniType.int_, 'nope'),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('expected a int'),
          ),
        ),
      );
      expect(
        () => object.setField('booleanField', JniType.boolean, 1),
        throwsA(isA<JniError>()),
      );
    });
  });

  group('static fields: read', () {
    test('every primitive type', () {
      expect(
        fixtures.getStaticField('staticBooleanField', JniType.boolean),
        isFalse,
      );
      expect(fixtures.getStaticField('staticByteField', JniType.byte), 127);
      expect(
        fixtures.getStaticField('staticCharField', JniType.char),
        'A'.codeUnitAt(0),
      );
      expect(fixtures.getStaticField('staticShortField', JniType.short), 32767);
      expect(
        fixtures.getStaticField('staticIntField', JniType.int_),
        -2147483648,
      );
      expect(
        fixtures.getStaticField('staticLongField', JniType.long),
        -9223372036854775808,
      );
      expect(fixtures.getStaticField('staticFloatField', JniType.float), -1.5);
      expect(
        fixtures.getStaticField('staticDoubleField', JniType.double_),
        -0.5,
      );
    });

    test('String', () {
      expect(
        fixtures.getStaticField('staticStringField', JniType.string),
        'static-initial',
      );
    });
  });

  group('static fields: write', () {
    test('every primitive type', () {
      fixtures.setStaticField('staticBooleanField', JniType.boolean, true);
      fixtures.setStaticField('staticByteField', JniType.byte, -128);
      fixtures.setStaticField('staticCharField', JniType.char, 0x00E7);
      fixtures.setStaticField('staticShortField', JniType.short, -32768);
      fixtures.setStaticField('staticIntField', JniType.int_, 2147483647);
      fixtures.setStaticField(
        'staticLongField',
        JniType.long,
        9223372036854775807,
      );
      fixtures.setStaticField('staticFloatField', JniType.float, 0.5);
      fixtures.setStaticField('staticDoubleField', JniType.double_, 0.25);

      expect(
        fixtures.getStaticField('staticBooleanField', JniType.boolean),
        isTrue,
      );
      expect(fixtures.getStaticField('staticByteField', JniType.byte), -128);
      expect(fixtures.getStaticField('staticCharField', JniType.char), 0x00E7);
      expect(
        fixtures.getStaticField('staticShortField', JniType.short),
        -32768,
      );
      expect(
        fixtures.getStaticField('staticIntField', JniType.int_),
        2147483647,
      );
      expect(
        fixtures.getStaticField('staticLongField', JniType.long),
        9223372036854775807,
      );
      expect(fixtures.getStaticField('staticFloatField', JniType.float), 0.5);
      expect(
        fixtures.getStaticField('staticDoubleField', JniType.double_),
        0.25,
      );
    });

    test('String', () {
      fixtures.setStaticField('staticStringField', JniType.string, 'updated');
      expect(
        fixtures.getStaticField('staticStringField', JniType.string),
        'updated',
      );
    });

    test('resetStatics restores the declared values', () {
      fixtures.setStaticField('staticIntField', JniType.int_, 1);
      fixtures.callStatic('resetStatics', '()V');
      expect(
        fixtures.getStaticField('staticIntField', JniType.int_),
        -2147483648,
      );
    });
  });

  group('field errors', () {
    test('an unknown field is a lookup error', () {
      expect(
        () => fixtures.getStaticField('nope', JniType.int_),
        throwsA(isA<JniLookupError>()),
      );
      expect(
        () => fixturesInstance(fixtures).getField('nope', JniType.int_),
        throwsA(isA<JniLookupError>()),
      );
    });

    test('the wrong descriptor for an existing field is a lookup error', () {
      // `intField` is I; asking for J must not silently read four bytes too
      // many.
      expect(
        () => fixturesInstance(fixtures).getField('intField', JniType.long),
        throwsA(isA<JniLookupError>()),
      );
    });

    test('"void" is rejected as a field type', () {
      expect(
        () => fixturesInstance(fixtures).getField('intField', JniType.void_),
        throwsA(isA<JniError>()),
      );
    });
  });

  group('raw field API', () {
    test('mirrors JNI one-to-one', () {
      final jvm = testJvm;
      final clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));
      final constructor = jvm.methodId(clazz, '<init>', '()V');
      final object = autoRelease(jvm.newObject(clazz, constructor));

      final intField = jvm.fieldId(clazz, 'intField', 'I');
      expect(jvm.getIntField(object, intField), 2147483647);

      jvm.setIntField(object, intField, 7);
      expect(jvm.getIntField(object, intField), 7);

      final staticInt = jvm.staticFieldId(clazz, 'staticIntField', 'I');
      jvm.setStaticIntField(clazz, staticInt, 99);
      expect(jvm.getStaticIntField(clazz, staticInt), 99);
    });
  });

  /// The descriptor-driven pair, reached directly rather than through
  /// `JavaObject.getField`.
  ///
  /// These checks are unreachable from the higher level, where resolving the
  /// `jfieldID` fails first on a descriptor JNI does not know. They still have
  /// to hold: the whole point of dispatching on the descriptor is that a type
  /// it does not understand becomes an error rather than a `GetIntField` on
  /// something that is not an int.
  group('getFieldByType and setFieldByType', () {
    late Jvm jvm;
    late JavaRef clazz;
    late JavaRef object;
    late Pointer<Void> intField;
    late Pointer<Void> stringField;

    setUp(() {
      jvm = testJvm;
      clazz = autoRelease(jvm.findClass('com.nfeflash.example.Fixtures'));
      object = autoRelease(
        jvm.newObject(clazz, jvm.methodId(clazz, '<init>', '()V')),
      );
      intField = jvm.fieldId(clazz, 'intField', 'I');
      stringField = jvm.fieldId(clazz, 'stringField', 'Ljava/lang/String;');
    });

    Matcher refusedWith(String fragment) => throwsA(
      isA<JniError>().having((e) => e.message, 'message', contains(fragment)),
    );

    test('a field cannot have type "void"', () {
      expect(
        () =>
            jvm.getFieldByType(JniType.void_, object, intField, static: false),
        refusedWith('a field cannot have type "void"'),
      );
      expect(
        () => jvm.setFieldByType(
          JniType.void_,
          object,
          intField,
          0,
          static: false,
        ),
        refusedWith('a field cannot have type "void"'),
      );
    });

    test('a descriptor that names no type at all is refused', () {
      expect(
        () => jvm.getFieldByType('Q', object, intField, static: false),
        refusedWith('unknown field descriptor'),
      );
      expect(
        () => jvm.setFieldByType('Q', object, intField, 0, static: false),
        refusedWith('unknown field descriptor'),
      );
    });

    test('a reference field takes a JavaRef or null, not a Dart value', () {
      // No conversion here on purpose: `JavaObject.setField` boxes and makes
      // strings, and this is the layer underneath it.
      expect(
        () => jvm.setFieldByType(
          JniType.string,
          object,
          stringField,
          'a Dart string',
          static: false,
        ),
        refusedWith('expected a JavaRef or null'),
      );

      jvm.setFieldByType(
        JniType.string,
        object,
        stringField,
        autoRelease(jvm.newString('já')),
        static: false,
      );
      expect(
        jvm.stringFrom(
          jvm.getFieldByType(JniType.string, object, stringField, static: false)
              as JavaRef,
        ),
        'já',
      );
    });

    test('a primitive field names the type it wanted', () {
      expect(
        () => jvm.setFieldByType(
          JniType.int_,
          object,
          intField,
          'seven',
          static: false,
        ),
        refusedWith('expected a int for field "I", got String'),
      );

      // `F` and `D` widen an int, so only a non-number is refused — and it is
      // refused by a different check than the integral types use.
      final floatField = jvm.fieldId(clazz, 'floatField', 'F');
      expect(
        () => jvm.setFieldByType(
          JniType.float,
          object,
          floatField,
          'half',
          static: false,
        ),
        refusedWith('expected a double for field "F", got String'),
      );
    });
  });
}
