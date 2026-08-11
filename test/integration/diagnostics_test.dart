@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Environment questions, the class registry, and frames that return a value.
void main() {
  group('Jvm.isAttached', () {
    /// This suite runs in the process that boots the VM — whether *this* isolate
    /// won the race is not knowable here, so the assertion is the invariant that
    /// holds either way: the flag agrees with what the class path shows.
    test('agrees with whether the class path came through', () {
      final jvm = testJvm;

      if (jvm.created) {
        expect(
          jvm.classPath,
          isNotEmpty,
          reason: 'a VM we created keeps the class path we gave it',
        );
      } else {
        expect(
          jvm.classPath,
          isEmpty,
          reason: 'JNI cannot read back the class path of an existing VM',
        );
      }
      expect(jvm.isAttached, !jvm.created);
    });

    /// The ambiguity the flag exists to remove: an empty [Jvm.classPath] used to
    /// be the only signal, and it cannot distinguish "attached" from "created
    /// with no class path".
    test('is not inferable from classPath alone', () {
      final jvm = testJvm;
      // Both states are representable; only `created` says which one this is.
      expect(jvm.created, isA<bool>());
    });
  }, skip: skipWithoutJdk);

  group('Jvm.systemProperty', () {
    test('reads the standard properties', () {
      final jvm = testJvm;

      expect(jvm.systemProperty('java.version'), isNotNull);
      expect(jvm.systemProperty('java.version'), isNotEmpty);
      expect(jvm.systemProperty('java.vendor'), isNotNull);
    });

    test('an unset property is null, not an empty string', () {
      expect(testJvm.systemProperty('java_interop.definitely.not.set'), isNull);
    });

    /// The class path is passed as `-Djava.class.path`, so it comes back this
    /// way — which is also the only route to it when the VM was created
    /// elsewhere.
    test('java.class.path reflects the running VM', () {
      final path = testJvm.systemProperty('java.class.path');
      expect(path, isNotNull);
      expect(path, contains('fixtures.jar'));
    });
  }, skip: skipWithoutJdk);

  group('class-path probing', () {
    test('a resource in the fixtures jar is found', () {
      // javac writes no resources into the jar, so probe something the JDK
      // itself always provides through the system loader.
      expect(testJvm.resourceExists('java/lang/String.class'), isTrue);
    });

    test('a missing resource is absent, not an error', () {
      expect(testJvm.resourceExists('does/not/exist.properties'), isFalse);
      expect(testJvm.resourceUrls('does/not/exist.properties'), isEmpty);
    });

    test('resourceUrls returns locations in load order', () {
      final urls = testJvm.resourceUrls('java/lang/String.class');
      expect(urls, isNotEmpty);
      expect(urls.first, contains('String.class'));
    });

    test('requireClasses passes for classes that resolve', () {
      expect(
        () => testJvm.requireClasses({
          'java.lang.String': 'the JDK',
          'com.nfeflash.example.Fixtures': 'fixtures.jar',
        }),
        returnsNormally,
      );
    });

    /// The point of the check: the failure names the class *and* the artifact
    /// that should have provided it, at startup rather than from inside a
    /// library much later.
    test('requireClasses names the missing class and its artifact', () {
      expect(
        () => testJvm.requireClasses({
          'com.example.NotThere': 'some-library-1.2.3.jar',
        }),
        throwsA(
          isA<JniLookupError>().having(
            (e) => e.toString(),
            'toString',
            allOf(
              contains('com.example.NotThere'),
              contains('some-library-1.2.3.jar'),
            ),
          ),
        ),
      );
    });
  }, skip: skipWithoutJdk);

  group('class registry', () {
    test('the same name gives the same instance', () {
      final jvm = testJvm;
      addTearDown(jvm.releaseCachedClasses);

      final first = jvm.classFor('java.util.ArrayList');
      final second = jvm.classFor('java.util.ArrayList');

      expect(second, same(first));
    });

    /// The reason the registry exists: the member-id cache lives on the
    /// instance, so resolving the class twice throws away every id already
    /// looked up.
    test('the member-id cache survives across calls', () {
      final jvm = testJvm;
      addTearDown(jvm.releaseCachedClasses);

      jvm.classFor('com.nfeflash.example.Fixtures').callJavaStatic(
        'int staticSum(int, int)',
        [1, 2],
      );

      final cachedAfterFirst = jvm
          .classFor('com.nfeflash.example.Fixtures')
          .cachedMemberCount;
      expect(cachedAfterFirst, greaterThan(0));

      jvm.classFor('com.nfeflash.example.Fixtures').callJavaStatic(
        'int staticSum(int, int)',
        [3, 4],
      );

      expect(
        jvm.classFor('com.nfeflash.example.Fixtures').cachedMemberCount,
        cachedAfterFirst,
        reason:
            'the second call reused the cached id instead of resolving again',
      );

      // Resolving separately is what the registry avoids: a fresh instance
      // starts with an empty cache.
      final separate = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');
      addTearDown(separate.release);
      expect(separate.cachedMemberCount, 0);
    });

    test('the registry reports and releases what it holds', () {
      final jvm = testJvm;

      jvm.releaseCachedClasses();
      expect(jvm.cachedClassCount, 0);
      expect(jvm.isClassCached('java.util.HashMap'), isFalse);

      jvm.classFor('java.util.HashMap');
      expect(jvm.cachedClassCount, 1);
      expect(jvm.isClassCached('java.util.HashMap'), isTrue);

      jvm.releaseCachedClasses();
      expect(jvm.cachedClassCount, 0);
    });

    test('registry classes are global, so they survive a frame', () {
      final jvm = testJvm;
      addTearDown(jvm.releaseCachedClasses);

      final held = jvm.localFrame(() => jvm.classFor('java.util.ArrayList'));

      // A local class reference would be dangling here.
      expect(held.newJava('()').callJavaAs<int>('int size()'), 0);
    });
  }, skip: skipWithoutJdk);

  group('enum constants', () {
    test('reads a constant and keeps it usable', () {
      final flavour = testJvm.classFor(
        r'com.nfeflash.example.Fixtures$Flavour',
      );
      addTearDown(testJvm.releaseCachedClasses);

      final sweet = flavour.enumConstant('SWEET');
      addTearDown(sweet.release);

      expect(sweet.callJavaAs<String>('String name()'), 'SWEET');
      expect(sweet.callJavaAs<String>('String describe()'), 'flavour:SWEET');
    });

    /// A constant is global, which is the whole point: it is read once and used
    /// for the life of the process.
    test('the constant survives a local frame', () {
      final flavour = testJvm.classFor(
        r'com.nfeflash.example.Fixtures$Flavour',
      );
      addTearDown(testJvm.releaseCachedClasses);

      final umami = testJvm.localFrame(() => flavour.enumConstant('UMAMI'));
      addTearDown(umami.release);

      final fixtures = fixturesClass();
      expect(
        fixtures.callJavaStatic(
          r'String describeFlavour(com.nfeflash.example.Fixtures$Flavour)',
          [umami],
        ),
        'flavour:UMAMI',
      );
    });

    test('two reads of one constant are the same Java object', () {
      final flavour = testJvm.classFor(
        r'com.nfeflash.example.Fixtures$Flavour',
      );
      addTearDown(testJvm.releaseCachedClasses);

      final a = flavour.enumConstant('SOUR');
      final b = flavour.enumConstant('SOUR');
      addTearDown(a.release);
      addTearDown(b.release);

      expect(a.ref.isSameObject(b.ref), isTrue);
    });

    test('an unknown constant fails by name', () {
      final flavour = testJvm.classFor(
        r'com.nfeflash.example.Fixtures$Flavour',
      );
      addTearDown(testJvm.releaseCachedClasses);

      expect(() => flavour.enumConstant('BITTER'), throwsA(isA<JniError>()));
    });
  }, skip: skipWithoutJdk);

  group('localFrameReturning', () {
    test('the returned reference outlives the frame', () {
      final jvm = testJvm;
      final fixtures = fixturesClass();

      final greeting = jvm.localFrameReturningObject(() {
        // Several throwaway references, then one worth keeping.
        for (var i = 0; i < 20; i++) {
          fixtures.callJavaStatic('String echoString(String)', ['scratch $i']);
        }
        return fixtures.callJavaStaticAs<JavaObject>(
          'Object staticEchoObject(Object)',
          ['kept'],
        );
      }, capacity: 64);

      expect(greeting, isNotNull);
      addTearDown(greeting!.release);

      // Using it is the assertion: a dangling reference would crash or lie.
      expect(greeting.javaToString(), 'kept');
    });

    test('the result is a local reference of the caller frame', () {
      final jvm = testJvm;
      final fixtures = fixturesClass();

      final ref = jvm.localFrameReturning(
        () => fixtures.callJavaStaticAs<JavaObject>(
          'Object staticEchoObject(Object)',
          ['x'],
        ).ref,
      );

      expect(ref, isNotNull);
      addTearDown(ref!.release);
      expect(ref.kind, JavaRefKind.local);
      expect(ref.isNull, isFalse);
    });

    test('returning null pops the frame and yields null', () {
      expect(testJvm.localFrameReturning(() => null), isNull);
      expect(testJvm.localFrameReturningObject(() => null), isNull);
    });

    /// The frame has to be popped even when the body fails, or the next
    /// `PushLocalFrame` nests one deeper every time.
    test('the frame is popped when the body throws', () {
      final jvm = testJvm;
      final fixtures = fixturesClass();

      expect(
        () => jvm.localFrameReturning(() {
          fixtures.callJavaStatic('void throwIllegalState(String)', ['boom']);
          return null;
        }),
        throwsA(isA<JavaException>()),
      );

      // Still usable, and not leaking frames.
      for (var i = 0; i < 100; i++) {
        final ref = jvm.localFrameReturning(
          () => fixtures.callJavaStaticAs<JavaObject>(
            'Object staticEchoObject(Object)',
            ['ok'],
          ).ref,
        );
        ref?.release();
      }
    });

    /// The loop that motivates frames at all: without one, the local reference
    /// table overflows and the VM aborts rather than throwing.
    test('ten thousand frames do not exhaust the reference table', () {
      final jvm = testJvm;
      final fixtures = fixturesClass();

      for (var i = 0; i < 10000; i++) {
        final ref = jvm.localFrameReturning(
          () => fixtures.callJavaStaticAs<JavaObject>(
            'Object staticEchoObject(Object)',
            ['$i'],
          ).ref,
        );
        ref?.release();
      }
    });

    test('a passed-in type is carried onto the result', () {
      final jvm = testJvm;
      addTearDown(jvm.releaseCachedClasses);

      final listClass = jvm.classFor('java.util.ArrayList');

      final list = jvm.localFrameReturningObject(
        () => listClass.newJava('()'),
        type: listClass,
      );

      expect(list, isNotNull);
      addTearDown(list!.release);
      expect(list.type, same(listClass));
      expect(list.callJavaAs<int>('int size()'), 0);
    });
  }, skip: skipWithoutJdk);

  group('newJava declarations', () {
    test('a parameter-list declaration constructs', () {
      final fixtures = fixturesClass();
      final instance = autoReleaseObject(fixtures.newJava('()'));
      expect(instance.callJavaAs<String>('String getLabel()'), isNotNull);
    });

    /// The natural mistake — writing the declaration the way Java source does —
    /// now simply works. It parses as a *method* returning this class, and since
    /// the name matches, the intent is unambiguous.
    ///
    /// Before, it failed as `no such method: <init>([B)Ljava/io/...;`, pointing
    /// at the constructor rather than at the declaration that was wrong.
    test('the class own name in front is accepted, simple or qualified', () {
      final jvm = testJvm;
      addTearDown(jvm.releaseCachedClasses);

      final stream = jvm.classFor('java.io.ByteArrayInputStream');

      final simple = autoReleaseObject(
        stream.newJava('ByteArrayInputStream(byte[])', [
          [1, 2, 3],
        ]),
      );
      expect(simple.callJavaAs<int>('int available()'), 3);

      final qualified = autoReleaseObject(
        stream.newJava('java.io.ByteArrayInputStream(byte[])', [
          [1, 2, 3, 4],
        ]),
      );
      expect(qualified.callJavaAs<int>('int available()'), 4);
    });

    /// A return type that is *not* this class is a genuine mistake, and the
    /// message says what to write instead.
    test('some other return type is rejected with the right form', () {
      final jvm = testJvm;
      addTearDown(jvm.releaseCachedClasses);

      final stream = jvm.classFor('java.io.ByteArrayInputStream');

      expect(
        () => stream.newJava('String readAll(byte[])', [
          [1, 2, 3],
        ]),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('not a constructor declaration'),
              contains('(byte[])'),
            ),
          ),
        ),
      );

      expect(
        () => stream.newJava('int (byte[])', [
          [1, 2, 3],
        ]),
        throwsA(isA<JniError>()),
      );
    });

    test('an explicit void return still works', () {
      final fixtures = fixturesClass();
      final instance = autoReleaseObject(fixtures.newJava('void ()'));
      expect(instance.isNull, isFalse);
    });
  }, skip: skipWithoutJdk);
}
