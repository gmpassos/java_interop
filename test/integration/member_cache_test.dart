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

  group('member id cache', () {
    test('resolving the same method twice returns the same id', () {
      final first = fixtures.staticMethodId('staticSum', '(II)I');
      final second = fixtures.staticMethodId('staticSum', '(II)I');

      expect(second, first);
      expect(fixtures.cachedMemberCount, 1);
    });

    test('each kind of member gets its own cache entry', () {
      fixtures
        ..methodId('getLabel', '()Ljava/lang/String;')
        ..staticMethodId('staticSum', '(II)I')
        ..fieldId('intField', JniType.int_)
        ..staticFieldId('staticIntField', JniType.int_);

      expect(fixtures.cachedMemberCount, 4);
    });

    test('a name shared by a method and a field does not collide', () {
      final method = fixtures.staticMethodId('staticSum', '(II)I');
      final field = fixtures.staticFieldId('staticIntField', JniType.int_);

      expect(method, isNot(field));
      expect(fixtures.cachedMemberCount, 2);
    });

    test('overloads are cached separately', () {
      fixtures
        ..methodId('<init>', '()V')
        ..methodId('<init>', '(Ljava/lang/String;)V')
        ..methodId('<init>', '(Ljava/lang/String;I)V');

      expect(fixtures.cachedMemberCount, 3);
    });

    test('a failed lookup is not cached', () {
      expect(
        () => fixtures.methodId('noSuchMethod', '()V'),
        throwsA(isA<JniLookupError>()),
      );
      expect(
        () => fixtures.methodId('noSuchMethod', '()V'),
        throwsA(isA<JniLookupError>()),
        reason: 'still throws, rather than returning a cached null',
      );
      expect(fixtures.cachedMemberCount, 0);
    });

    test('calling repeatedly resolves the id once', () {
      final instance = fixtures.newInstance('(Ljava/lang/String;I)V', ['x', 5]);
      addTearDown(instance.release);

      // The constructor is the only member resolved so far.
      expect(fixtures.cachedMemberCount, 1);

      for (var i = 0; i < 10; i++) {
        expect(instance.call('sum', '(II)I', [i, 1]), i + 1);
      }

      // `instance` was built from `fixtures`, so it shares that cache.
      expect(fixtures.cachedMemberCount, 2);
    });

    test('release drops the cache', () {
      final clazz = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');
      clazz.staticMethodId('staticSum', '(II)I');
      expect(clazz.cachedMemberCount, 1);

      clazz.release();
      expect(clazz.cachedMemberCount, 0);
    });
  });

  group('runtime class caching', () {
    test('type is resolved once and reused', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.type, same(instance.type));
    });

    test('an object built from a class shares that class', () {
      final instance = fixturesInstance(fixtures);
      expect(instance.type, same(fixtures));
    });

    test('an object without a declared class resolves its own', () {
      final echoed =
          fixtures.callStatic(
                'staticEchoObject',
                '(Ljava/lang/Object;)Ljava/lang/Object;',
                ['text'],
              )
              as JavaObject;
      addTearDown(echoed.release);

      expect(echoed.type.name, 'java.lang.String');
      // Resolved lazily, then held: the id cache below lives on it.
      expect(echoed.type, same(echoed.type));
      expect(echoed.call('length', '()I'), 4);
      expect(echoed.type.cachedMemberCount, 1);
    });

    test('releasing an object releases the class it resolved itself', () {
      final echoed =
          fixtures.callStatic(
                'staticEchoObject',
                '(Ljava/lang/Object;)Ljava/lang/Object;',
                ['text'],
              )
              as JavaObject;

      final resolved = echoed.type;
      echoed.release();

      expect(resolved.ref.isReleased, isTrue);
    });

    test('releasing an object does not release a class it was handed', () {
      final instance = fixtures.newInstance();
      instance.release();

      expect(
        fixtures.ref.isReleased,
        isFalse,
        reason: 'the class belongs to whoever created it',
      );
      expect(fixtures.callStatic('staticSum', '(II)I', [1, 1]), 2);
    });
  });

  group('null receivers', () {
    test('calling a method on a Java null is refused, not crashed', () {
      // objectField is initialised to null on the Java side.
      final holder = fixturesInstance(fixtures);
      final nullValue =
          holder.getField('objectField', JniType.object) as JavaObject;
      addTearDown(nullValue.release);
      expect(nullValue.isNull, isTrue);

      expect(
        () => nullValue.call('toString', '()Ljava/lang/String;'),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('Java null'),
          ),
        ),
      );
    });

    test('reading a field on a Java null is refused', () {
      final holder = fixturesInstance(fixtures);
      final nullValue =
          holder.getField('objectField', JniType.object) as JavaObject;
      addTearDown(nullValue.release);

      expect(
        () => nullValue.getField('intField', JniType.int_),
        throwsA(isA<JniError>()),
      );
    });
  });
}
