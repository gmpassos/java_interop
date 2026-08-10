@TestOn('vm')
library;

import 'dart:ffi';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  late Jvm jvm;
  late JavaClass fixtures;

  setUpAll(() => jvm = testJvm);
  setUp(() => fixtures = fixturesClass());

  /// `Fixtures.classOf(value)` — the runtime class Java actually received.
  String? classOf(Object? value) =>
      fixtures.callStatic('classOf', '(Ljava/lang/Object;)Ljava/lang/String;', [
            value,
          ])
          as String?;

  group('declared wrapper parameters', () {
    test('an int boxes exactly into the declared wrapper', () {
      expect(
        fixtures.callStatic('unboxInteger', '(Ljava/lang/Integer;)I', [42]),
        42,
      );
    });

    test('null passes through as a null wrapper', () {
      expect(
        fixtures.callStatic('unboxInteger', '(Ljava/lang/Integer;)I', [null]),
        -1,
      );
    });

    test('a bool for an Integer parameter is rejected', () {
      expect(
        () => fixtures.callStatic('unboxInteger', '(Ljava/lang/Integer;)I', [
          true,
        ]),
        throwsA(isA<JniError>()),
      );
    });
  });

  group('declared wrapper results', () {
    test('an Integer result is unboxed', () {
      expect(
        fixtures.callStatic('boxInteger', '(I)Ljava/lang/Integer;', [7]),
        7,
      );
      expect(
        fixtures.callStatic('boxInteger', '(I)Ljava/lang/Integer;', [7]),
        isA<int>(),
      );
    });

    test('a null wrapper result stays null, not zero', () {
      expect(fixtures.callStatic('nullInteger', '()Ljava/lang/Integer;'), null);
    });

    test('the other wrappers unbox to their Dart equivalents', () {
      expect(fixtures.callStatic('boxLong', '(J)Ljava/lang/Long;', [8]), 8);
      expect(
        fixtures.callStatic('boxDouble', '(D)Ljava/lang/Double;', [1.5]),
        1.5,
      );
      expect(
        fixtures.callStatic('boxBoolean', '(Z)Ljava/lang/Boolean;', [true]),
        isTrue,
      );
    });
  });

  group('erased parameters infer a wrapper', () {
    test('an int that fits becomes an Integer', () {
      expect(classOf(42), 'java.lang.Integer');
      expect(classOf(2147483647), 'java.lang.Integer');
      expect(classOf(-2147483648), 'java.lang.Integer');
    });

    test('an int that does not fit becomes a Long', () {
      expect(classOf(2147483648), 'java.lang.Long');
      expect(classOf(-2147483649), 'java.lang.Long');
    });

    test('a double becomes a Double and a bool a Boolean', () {
      expect(classOf(1.5), 'java.lang.Double');
      expect(classOf(true), 'java.lang.Boolean');
    });

    test('a String is still a String, not a box', () {
      expect(classOf('text'), 'java.lang.String');
    });

    test('an explicit box overrides the inferred width', () {
      final long = autoRelease(jvm.boxLong(42));
      expect(classOf(long), 'java.lang.Long');
    });
  });

  group('explicit boxing', () {
    test('every wrapper round-trips through box and unbox', () {
      final cases = <JavaWrapper, Object>{
        JavaWrapper.boolean: true,
        JavaWrapper.byte: -128,
        JavaWrapper.char: 0x4e2d,
        JavaWrapper.short: -32768,
        JavaWrapper.int_: 2147483647,
        JavaWrapper.long: 9223372036854775807,
        JavaWrapper.float: 1.5,
        JavaWrapper.double_: 2.718281828459045,
      };

      cases.forEach((wrapper, value) {
        final boxed = autoRelease(jvm.boxAs(wrapper, value));
        expect(
          jvm.unboxAs(wrapper, boxed),
          value,
          reason: '${wrapper.className} round trip',
        );
        expect(jvm.wrapperOf(boxed), same(wrapper));
      });
    });

    test('the typed helpers agree with boxAs', () {
      expect(
        jvm.unbox(JavaWrapper.int_.descriptor, autoRelease(jvm.boxInt(1))),
        1,
      );
      expect(
        jvm.unbox(
          JavaWrapper.double_.descriptor,
          autoRelease(jvm.boxDouble(2.5)),
        ),
        2.5,
      );
      expect(
        jvm.unbox(
          JavaWrapper.boolean.descriptor,
          autoRelease(jvm.boxBoolean(false)),
        ),
        isFalse,
      );
    });

    test('unboxing a null reference gives null', () {
      final nullRef = JavaRef(jvm, nullptr, JavaRefKind.local);
      expect(jvm.unboxAs(JavaWrapper.int_, nullRef), isNull);
    });

    test('canBox is false for types that are not boxes', () {
      expect(jvm.canBox(JniType.object), isTrue);
      expect(jvm.canBox(JavaWrapper.int_.descriptor), isTrue);
      expect(jvm.canBox(JniType.string), isFalse);
      expect(jvm.canBox('[I'), isFalse);
    });

    test('boxing into a non-wrapper type is refused', () {
      expect(
        () => jvm.box(JniType.string, 1),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('not a primitive wrapper type'),
          ),
        ),
      );
      expect(
        () => fixtures.callStatic(
          'echoString',
          '(Ljava/lang/String;)Ljava/lang/String;',
          [1],
        ),
        throwsA(isA<JniError>()),
      );
    });

    test('a bool cannot be inferred for a Number parameter', () {
      expect(
        () => jvm.box('Ljava/lang/Number;', true),
        throwsA(isA<JniError>()),
      );
    });
  });

  group('toDart', () {
    test('unboxes what an Object-declared result hides', () {
      final echoed =
          fixtures.callStatic(
                'staticEchoObject',
                '(Ljava/lang/Object;)Ljava/lang/Object;',
                [7],
              )
              as JavaObject;
      addTearDown(echoed.release);

      expect(echoed.toDart(), 7);
    });

    test('converts a String hidden behind Object', () {
      final echoed =
          fixtures.callStatic(
                'staticEchoObject',
                '(Ljava/lang/Object;)Ljava/lang/Object;',
                ['text'],
              )
              as JavaObject;
      addTearDown(echoed.release);

      expect(echoed.toDart(), 'text');
    });

    test('returns the object itself when it is not convertible', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.toDart(), same(instance));
    });

    test('leaves the reference usable afterwards', () {
      final echoed =
          fixtures.callStatic(
                'staticEchoObject',
                '(Ljava/lang/Object;)Ljava/lang/Object;',
                [7],
              )
              as JavaObject;
      addTearDown(echoed.release);

      expect(echoed.toDart(), 7);
      expect(echoed.javaToString(), '7');
    });
  });

  group('boxed fields', () {
    test('reads a wrapper field as a Dart int', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.getField('boxedIntField', 'Ljava/lang/Integer;'), 7);
    });

    test('writes a wrapper field from a Dart int', () {
      final instance = fixturesInstance(fixtures);
      instance.setField('boxedIntField', 'Ljava/lang/Integer;', 99);
      expect(instance.getField('boxedIntField', 'Ljava/lang/Integer;'), 99);
    });

    test('writes null to a wrapper field', () {
      final instance = fixturesInstance(fixtures);
      instance.setField('boxedIntField', 'Ljava/lang/Integer;', null);
      expect(instance.getField('boxedIntField', 'Ljava/lang/Integer;'), isNull);
    });
  });

  group('generic collections', () {
    test('an ArrayList of ints is built and summed from Dart', () {
      final listClass = JavaClass.forName(jvm, 'java.util.ArrayList');
      addTearDown(listClass.release);

      final list = listClass.newInstance();
      addTearDown(list.release);

      for (final value in [1, 2, 3]) {
        expect(list.call('add', '(Ljava/lang/Object;)Z', [value]), isTrue);
      }

      expect(list.call('size', '()I'), 3);
      expect(fixtures.callStatic('sumList', '(Ljava/util/List;)I', [list]), 6);
    });

    test('a HashMap keyed by Dart values round-trips', () {
      final mapClass = JavaClass.forName(jvm, 'java.util.HashMap');
      addTearDown(mapClass.release);

      final map = mapClass.newInstance();
      addTearDown(map.release);

      const put = '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;';
      map.call('put', put, ['answer', 42]);

      final got =
          map.call('get', '(Ljava/lang/Object;)Ljava/lang/Object;', ['answer'])
              as JavaObject;
      addTearDown(got.release);

      expect(got.toDart(), 42);
    });
  });
}
