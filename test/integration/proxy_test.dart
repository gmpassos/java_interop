@TestOn('vm')
library;

import 'dart:isolate';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Java interfaces implemented in Dart.
///
/// The tests that matter most are the ones about *which thread* and *what
/// happens after release*: both failure modes abort the process rather than
/// throwing, so a regression there would not show up as a red test but as a
/// dead test runner.
void main() {
  group('proxies', () {
    tearDown(() {
      // Each test gets the machinery fresh, so a leaked binding or a proxy left
      // in the registry cannot make the next test pass or fail for the wrong
      // reason.
      testJvm.releaseProxyRuntime();
    });

    /// The capability in one test: the JDK's own sort, driven by Dart.
    test('a Comparator implemented in Dart orders a real Arrays.sort', () {
      final compares = <List<Object?>>[];
      final descending = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) {
          compares.add(call.args);
          return (call.args[1] as int).compareTo(call.args[0] as int);
        },
      );
      addTearDown(descending.release);

      final values = autoReleaseObject(
        JavaArray.ofObjects(testJvm, 'java.lang.Integer', [5, 3, 9, 1, 7]),
      );

      testJvm.classFor('java.util.Arrays').callJavaStatic(
        'void sort(Object[], java.util.Comparator)',
        [values, descending.instance],
      );

      expect(values.toList(), [9, 7, 5, 3, 1]);
      expect(compares, isNotEmpty);
      expect(compares.first, hasLength(2));
    });

    test('arguments arrive as Dart values, including null', () {
      Object? first;
      Object? second;
      var name = '';
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) {
          name = call.methodName;
          first = call.args[0];
          second = call.args[1];
          return 0;
        },
      );
      addTearDown(proxy.release);

      fixturesClass().callJavaStatic(
        'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
        [proxy.instance, 'left', null, 1],
      );

      expect(name, 'compare');
      expect(first, 'left');
      expect(second, isNull);
    });

    test('a JavaObject argument is usable', () {
      String? described;
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) {
          final flavour = call.args[0] as JavaObject;
          described = flavour.callJava('String describe()') as String;
          return 0;
        },
      );
      addTearDown(proxy.release);

      final flavours = testJvm.classFor(
        r'com.nfeflash.example.Fixtures$Flavour',
      );
      final sour = autoReleaseObject(flavours.enumConstant('SOUR'));

      fixturesClass().callJavaStatic(
        'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
        [proxy.instance, sour, sour, 1],
      );

      expect(described, 'flavour:SOUR');
    });

    test('handlers dispatch by name and onInvoke takes the rest', () {
      final calls = <String>[];
      final proxy = testJvm.implementInterfaces(
        ['java.lang.Runnable', 'java.util.Comparator'],
        handlers: {
          'run': (call) {
            calls.add('run');
            return null;
          },
        },
        onInvoke: (call) {
          calls.add('fallback:${call.methodName}');
          return 0;
        },
      );
      addTearDown(proxy.release);

      final fixtures = fixturesClass();
      fixtures.callJavaStatic('void run(Runnable)', [proxy.instance]);
      fixtures.callJavaStatic(
        'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
        [proxy.instance, 1, 2, 1],
      );

      expect(calls, ['run', 'fallback:compare']);
    });

    test('a method with no handler at all fails in Java', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'notRun': (call) => null},
      );
      addTearDown(proxy.release);

      final outcome = fixturesClass().callJavaStatic(
        'String runCatching(Runnable)',
        [proxy.instance],
      );

      expect(outcome, contains('no handler for run'));
    });

    test('a void method runs on the calling thread', () {
      var ran = 0;
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => ran++},
      );
      addTearDown(proxy.release);

      fixturesClass().callJavaStatic('void run(Runnable)', [proxy.instance]);
      fixturesClass().callJavaStatic('void run(Runnable)', [proxy.instance]);

      expect(ran, 2);
    });

    test('a Dart error becomes a Java exception', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => throw StateError('deliberate')},
      );
      addTearDown(proxy.release);

      final outcome = fixturesClass().callJavaStatic(
        'String runCatching(Runnable)',
        [proxy.instance],
      );

      expect(outcome, startsWith('java.lang.RuntimeException:'));
      expect(outcome, contains('deliberate'));
    });

    /// A Java exception that passed through a Dart handler should reach the Java
    /// caller as the class it started as, or an upstream `catch` stops matching.
    test('a Java exception keeps its class on the way back', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {
          'run': (call) => fixturesClass().callJavaStatic(
            'void throwIllegalState(String)',
            ['from the handler'],
          ),
        },
      );
      addTearDown(proxy.release);

      final outcome = fixturesClass().callJavaStatic(
        'String runCatching(Runnable)',
        [proxy.instance],
      );

      expect(outcome, 'java.lang.IllegalStateException: from the handler');
    });

    /// Reporting a Dart failure to Java must not become a second, worse
    /// failure. A [JavaException] is re-thrown as its own class where possible —
    /// but nothing guarantees that class is findable, and if `ThrowNew` were
    /// left to fail here, Java would carry on with a null return and no pending
    /// exception.
    test('an unfindable exception class falls back to RuntimeException', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {
          'run': (call) => throw JavaException(
            className: 'com.example.NotOnAnyClassPath',
            message: 'thrown by the handler',
          ),
        },
      );
      addTearDown(proxy.release);

      final outcome = fixturesClass().callJavaStatic(
        'String runCatching(Runnable)',
        [proxy.instance],
      );

      expect(outcome, startsWith('java.lang.RuntimeException:'));
      expect(outcome, contains('com.example.NotOnAnyClassPath'));
    });

    test('a proxy and a call describe themselves', () {
      String? described;
      final proxy = testJvm.implementInterfaces(
        ['java.lang.Runnable', 'java.util.Comparator'],
        onInvoke: (call) {
          described = call.toString();
          return 0;
        },
      );

      expect(
        proxy.toString(),
        'JavaProxy(java.lang.Runnable, java.util.Comparator)',
      );

      fixturesClass().callJavaStatic(
        'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
        [proxy.instance, 1, 2, 1],
      );

      expect(described, 'JavaProxyCall(compare, 2 args)');

      proxy.release();
      expect(proxy.toString(), endsWith(', released)'));
    });

    test('a queued call says so in its description', () async {
      String? described;
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {
          'run': (call) {
            described = call.toString();
            return null;
          },
        },
      );
      addTearDown(proxy.release);

      fixturesClass().callJavaStatic('void runOnNewThread(Runnable)', [
        proxy.instance,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(described, 'JavaProxyCall(run, 0 args, queued)');
    });

    test('toString, equals and hashCode work with no handler for them', () {
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) => fail('the Object methods must not reach here'),
      );
      addTearDown(proxy.release);

      final fixtures = fixturesClass();
      expect(
        fixtures.callJavaStatic('String textOf(Object)', [proxy.instance]),
        allOf(startsWith('DartProxy['), contains('java.util.Comparator')),
      );
      expect(
        fixtures.callJavaStatic('boolean equalsOf(Object, Object)', [
          proxy.instance,
          proxy.instance,
        ]),
        isTrue,
      );
      expect(
        fixtures.callJavaStatic('boolean survivesAHashSet(Object)', [
          proxy.instance,
        ]),
        isTrue,
        reason: 'a proxy has to be hashable to reach any collection',
      );
    });

    test('forwardObjectMethods hands them to the handler instead', () {
      final seen = <String>[];
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        forwardObjectMethods: true,
        onInvoke: (call) {
          seen.add(call.methodName);
          return switch (call.methodName) {
            'toString' => 'a Dart comparator',
            'hashCode' => 42,
            _ => null,
          };
        },
      );
      addTearDown(proxy.release);

      expect(
        fixturesClass().callJavaStatic('String textOf(Object)', [
          proxy.instance,
        ]),
        'a Dart comparator',
      );
      expect(
        fixturesClass().callJavaStatic('int hashOf(Object)', [proxy.instance]),
        42,
      );
      expect(seen, ['toString', 'hashCode']);
    });

    /// The failure mode that must never be a deadlock.
    test('a value asked for from a JVM thread is refused, not awaited', () {
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) => 0,
      );
      addTearDown(proxy.release);

      final outcome =
          fixturesClass().callJavaStatic(
                'String compareOnNewThread(java.util.Comparator, Object, Object)',
                [proxy.instance, 1, 2],
              )
              as String;

      expect(outcome, startsWith('java.lang.IllegalStateException:'));
      expect(outcome, contains('java.util.Comparator.compare'));
      expect(outcome, contains('deadlock'));
      // Both threads are named, so the message says what to do about it.
      expect(outcome, contains('fixtures-comparer'));
    });

    test('a void method from a JVM thread is queued, then delivered', () async {
      final calls = <bool>[];
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => calls.add(call.isQueued)},
      );
      addTearDown(proxy.release);

      fixturesClass().callJavaStatic('void runOnNewThread(Runnable)', [
        proxy.instance,
      ]);

      // The JVM thread has already run and been joined.
      expect(calls, isEmpty, reason: 'a queued call cannot run synchronously');
      expect(testJvm.queuedProxyCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(calls, [true], reason: 'and it is marked as queued');
      expect(testJvm.queuedProxyCalls, 0);
    });

    /// The arguments of a queued call outlive the frame that made it only
    /// because Java holds them; this is that guarantee.
    test('a queued call still has its arguments', () async {
      final seen = <Object?>[];
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {
          'run': (call) {
            seen.add(call.methodName);
            seen.add(call.args.length);
            return null;
          },
        },
      );
      addTearDown(proxy.release);

      fixturesClass().callJavaStatic('void runOnNewThread(Runnable)', [
        proxy.instance,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, ['run', 0]);
    });

    /// A queued call has no Java caller left to throw to — it returned when the
    /// call was queued — so an error in the handler has nowhere to go but
    /// [onQueuedError]. Without it the error surfaces as an unhandled isolate
    /// error, which is loud; being silent is the one thing it must not be.
    test('onQueuedError receives what a queued handler throws', () async {
      Object? caught;
      StackTrace? trace;

      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => throw StateError('queued failure')},
        onQueuedError: (error, stackTrace) {
          caught = error;
          trace = stackTrace;
        },
      );
      addTearDown(proxy.release);

      // Java is unaffected: it queued a void call and moved on.
      expect(
        () => fixturesClass().callJavaStatic('void runOnNewThread(Runnable)', [
          proxy.instance,
        ]),
        returnsNormally,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(caught, isA<StateError>());
      expect((caught! as StateError).message, 'queued failure');
      expect(trace, isNotNull);
      expect(
        testJvm.queuedProxyCalls,
        0,
        reason: 'a failed call is still taken off the queue',
      );
    });

    /// A released proxy, called from a JVM-owned thread: the one combination
    /// with no good answer. Java queues the call and returns, and by the time
    /// Dart looks there is no handler to run it and no `onQueuedError` to tell —
    /// that went with the proxy. Throwing would kill the isolate over something
    /// the caller could not prevent, so it is dropped and *counted*.
    test('a queued call for a released proxy is counted, not fatal', () async {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => fail('the handler is gone')},
      );

      final fixtures = fixturesClass();
      fixtures.callJavaStatic('void hold(Runnable)', [proxy.instance]);
      proxy.release();

      expect(testJvm.droppedProxyCalls, 0);

      // Java still holds the object, and calls it from its own thread.
      expect(
        fixtures.callJavaStatic('String runHeldOnNewThread()'),
        'no exception',
        reason:
            'a void method from a JVM thread is queued, so Java sees no '
            'failure',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(testJvm.droppedProxyCalls, 1);
      expect(
        testJvm.queuedProxyCalls,
        0,
        reason: 'the call is taken off the Java-side queue either way',
      );
    });

    /// Without a frame per call this overflows the local reference table, which
    /// JNI reports by aborting the VM.
    test('twenty thousand calls neither leak nor slow to a halt', () {
      var count = 0;
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) {
          count++;
          return 1;
        },
      );
      addTearDown(proxy.release);

      final last = fixturesClass().callJavaStatic(
        'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
        [proxy.instance, 'a', 'b', 20000],
      );

      expect(count, 20000);
      expect(last, 1);
    });

    /// Java may hold the object after Dart lets go of it. That has to throw in
    /// Java — the alternative is a call into a closed callable, which aborts the
    /// process.
    test('a call on a released proxy fails in Java', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => null},
      );

      final fixtures = fixturesClass();
      fixtures.callJavaStatic('void hold(Runnable)', [proxy.instance]);
      expect(fixtures.callJavaStatic('String runHeld()'), 'no exception');

      proxy.release();

      expect(
        fixtures.callJavaStatic('String runHeld()'),
        allOf(contains('RuntimeException'), contains('released proxy')),
      );
    });

    test('the instance is unusable from Dart after release', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => null},
      );
      proxy.release();

      expect(
        () => proxy.instance,
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('after release()'),
          ),
        ),
      );
      expect(proxy.isReleased, isTrue);
      expect(proxy.release, returnsNormally, reason: 'release is idempotent');
    });

    test('liveProxyCount follows creation and release', () {
      expect(testJvm.liveProxyCount, 0);

      final first = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => null},
      );
      final second = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => null},
      );
      expect(testJvm.liveProxyCount, 2);
      expect(testJvm.isProxyRuntimeLoaded, isTrue);

      first.release();
      expect(testJvm.liveProxyCount, 1);
      second.release();
      expect(testJvm.liveProxyCount, 0);
    });

    test('descriptor reports the JNI signature of the call', () {
      var descriptor = '';
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) {
          descriptor = call.descriptor;
          return 0;
        },
      );
      addTearDown(proxy.release);

      fixturesClass().callJavaStatic(
        'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
        [proxy.instance, 1, 2, 1],
      );

      expect(descriptor, '(Ljava/lang/Object;Ljava/lang/Object;)I');
    });

    test('one proxy can implement several interfaces', () {
      final proxy = testJvm.implementInterfaces([
        'java.lang.Runnable',
        'java.util.Comparator',
      ], onInvoke: (call) => call.methodName == 'compare' ? -1 : null);
      addTearDown(proxy.release);

      expect(proxy.interfaces, ['java.lang.Runnable', 'java.util.Comparator']);

      final fixtures = fixturesClass();
      expect(
        () => fixtures.callJavaStatic('void run(Runnable)', [proxy.instance]),
        returnsNormally,
      );
      expect(
        fixtures.callJavaStatic(
          'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
          [proxy.instance, 1, 2, 1],
        ),
        -1,
      );
    });

    /// Dart has one integer type, so the handler cannot know whether a method
    /// wants a `byte` or a `long`. The declared type decides, on the Java side.
    test('a return value is narrowed to each declared primitive type', () {
      final proxy = testJvm.implementInterface(
        r'com.nfeflash.example.Fixtures$Widths',
        onInvoke: (call) => switch (call.methodName) {
          'asBoolean' => true,
          // The same Dart int for four different integer widths, and one value
          // that only fits in a long.
          'asByte' => 65,
          'asChar' => 65,
          'asShort' => 65,
          'asInt' => 65,
          'asLong' => 9007199254740991,
          // The same Dart double for both float widths.
          'asFloat' => 1.5,
          'asDouble' => 1.5,
          'asString' => 'text',
          _ => null,
        },
      );
      addTearDown(proxy.release);

      expect(
        fixturesClass().callJavaStatic(
          r'String describeWidths(com.nfeflash.example.Fixtures$Widths)',
          [proxy.instance],
        ),
        'true,65,A,65,65,9007199254740991,1.5,1.5,text,null',
      );
    });

    test('returning the wrong type is reported, naming both', () {
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) => 'not a number',
      );
      addTearDown(proxy.release);

      expect(
        () => fixturesClass().callJavaStatic(
          'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
          [proxy.instance, 1, 2, 1],
        ),
        throwsA(
          isA<JavaException>()
              .having((e) => e.className, 'className', contains('ClassCast'))
              .having(
                (e) => e.message,
                'message',
                allOf(contains('java.lang.String'), contains('int')),
              ),
        ),
      );
    });

    test('returning null for a primitive is reported', () {
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) => null,
      );
      addTearDown(proxy.release);

      expect(
        () => fixturesClass().callJavaStatic(
          'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
          [proxy.instance, 1, 2, 1],
        ),
        throwsA(
          isA<JavaException>().having(
            (e) => e.message,
            'message',
            contains('returned null'),
          ),
        ),
      );
    });

    test('a handler returning an unconvertible Dart value says so', () {
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) => DateTime(2026),
      );
      addTearDown(proxy.release);

      expect(
        () => fixturesClass().callJavaStatic(
          'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
          [proxy.instance, 1, 2, 1],
        ),
        throwsA(
          isA<JavaException>().having(
            (e) => e.message,
            'message',
            contains('no Java equivalent'),
          ),
        ),
      );
    });

    /// An isolate is not pinned to an OS thread: awaiting an `Isolate.run` can
    /// resume it on the thread the child just freed. Reading [JavaProxy.instance]
    /// re-checks that, so the proxy keeps working either way.
    test('a proxy survives the isolate moving threads', () async {
      var calls = 0;
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) {
          calls++;
          return -1;
        },
      );
      addTearDown(proxy.release);

      final before = _compare(proxy);
      await moveOffThisThread();
      final after = _compare(proxy);

      expect([before, after], [-1, -1]);
      expect(calls, 2);
    });

    test('bindCurrentThread re-binds a cached instance', () async {
      final proxy = testJvm.implementInterface(
        'java.util.Comparator',
        onInvoke: (call) => -1,
      );
      addTearDown(proxy.release);

      // Held across the thread move, so nothing re-checks it implicitly.
      final cached = proxy.instance;
      await moveOffThisThread();
      proxy.bindCurrentThread();

      expect(
        fixturesClass().callJavaStatic(
          'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
          [cached, 1, 2, 1],
        ),
        -1,
      );
    });

    test('bindCurrentThread refuses a released proxy', () {
      final proxy = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => null},
      );
      proxy.release();

      expect(
        proxy.bindCurrentThread,
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('after release()'),
          ),
        ),
      );
    });

    test('the machinery can be torn down and built again', () {
      final first = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => null},
      );
      fixturesClass().callJavaStatic('void run(Runnable)', [first.instance]);

      testJvm.releaseProxyRuntime();
      expect(testJvm.isProxyRuntimeLoaded, isFalse);
      expect(first.isReleased, isTrue, reason: 'teardown releases its proxies');

      var ran = false;
      final second = testJvm.implementInterface(
        'java.lang.Runnable',
        handlers: {'run': (call) => ran = true},
      );
      addTearDown(second.release);
      fixturesClass().callJavaStatic('void run(Runnable)', [second.instance]);

      expect(ran, isTrue, reason: 'the class is defined in a fresh loader');
    });

    test('releaseProxyRuntime is safe when nothing was built', () {
      expect(testJvm.isProxyRuntimeLoaded, isFalse);
      expect(testJvm.releaseProxyRuntime, returnsNormally);
      expect(testJvm.queuedProxyCalls, 0);
      expect(testJvm.liveProxyCount, 0);
    });

    test('an empty interface list is rejected', () {
      expect(
        () => testJvm.implementInterfaces([], onInvoke: (call) => null),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('at least one interface'),
          ),
        ),
      );
    });

    test('a proxy with no way to handle anything is rejected', () {
      expect(
        () => testJvm.implementInterface('java.lang.Runnable'),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('onInvoke or handlers'),
          ),
        ),
      );
    });

    test('a class that is not an interface is rejected', () {
      expect(
        () => testJvm.implementInterface(
          'java.lang.String',
          onInvoke: (call) => null,
        ),
        throwsA(
          isA<JavaException>().having(
            (e) => e.message,
            'message',
            contains('is not an interface'),
          ),
        ),
      );
    });

    test('an interface that does not exist is reported as such', () {
      expect(
        () => testJvm.implementInterface(
          'com.example.NoSuchInterface',
          onInvoke: (call) => null,
        ),
        throwsA(
          isA<JavaException>().having(
            (e) => e.className,
            'className',
            'java.lang.ClassNotFoundException',
          ),
        ),
      );
    });
  }, skip: skipWithoutJdk);
}

/// Runs a throwaway isolate, which is enough to move this one onto another OS
/// thread — the child's, once the child has exited.
///
/// A top-level function so its closure captures nothing: a closure sharing a
/// scope with a [JavaProxy] would drag the proxy's `NativeCallable` into the
/// isolate message, which is rejected.
Future<void> moveOffThisThread() => Isolate.run(() => null);

/// One `compare` through [proxy].
Object? _compare(JavaProxy proxy) => fixturesClass().callJavaStatic(
  'int compareRepeatedly(java.util.Comparator, Object, Object, int)',
  [proxy.instance, 1, 2, 1],
);
