@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Java calls on JVM threads, and the reflective methods they are made with.
///
/// `com.nfeflash.example.Tasks` is package-private, so every method here also
/// proves the JDK 17+ `setAccessible` workaround in [JvmReflection].
void main() {
  const tasks = 'com.nfeflash.example.Tasks';

  JavaExecutor start({int threads = 1, String name = 'test-exec'}) {
    final executor = JavaExecutor.start(testJvm, threads: threads, name: name);
    addTearDown(executor.shutdown);
    return executor;
  }

  String? asString(JavaObject? result) => result?.toDart() as String?;

  tearDownAll(testJvm.releaseReflectedMethods);

  group('reflectMethod', () {
    test('finds a package-private method and caches it', () {
      final first = testJvm.reflectMethod(tasks, 'static String threadName()');
      final second = testJvm.reflectMethod(tasks, 'static String threadName()');
      expect(identical(first, second), isTrue);
      expect(first.callJavaAs<bool>('boolean isAccessible()'), isTrue);
    });

    test('tells overloads apart by their parameter types', () {
      String nameOf(String declaration) => testJvm
          .reflectMethod(tasks, declaration)
          .callJavaAs<String>('String toGenericString()');

      expect(nameOf('static String overloaded(int)'), contains('(int)'));
      expect(nameOf('static String overloaded(long)'), contains('(long)'));
      expect(
        nameOf('static String overloaded(String[])'),
        contains('(java.lang.String[])'),
      );
    });

    test('finds a private method of a superclass', () {
      final method = testJvm.reflectMethod(tasks, 'String inherited()');
      expect(
        method.callJavaAs<String>('String toGenericString()'),
        contains('TasksBase.inherited'),
      );
    });

    test('a method that does not exist is a JniError naming it', () {
      expect(
        () => testJvm.reflectMethod(tasks, 'static String missing(int)'),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('missing(int)'),
          ),
        ),
      );
    });
  });

  group('JavaExecutor', () {
    test('runs a static call and converts its result', () async {
      final executor = start();
      final echo = testJvm.reflectMethod(
        tasks,
        'static String sleepThenEcho(String, long)',
      );

      final result = await executor.run(echo, ['hello', 10], convert: asString);

      expect(result, 'hello');
      expect(executor.pending, 0);
    });

    test('runs an instance method on its target', () async {
      final executor = start();
      final instance = autoReleaseObject(
        testJvm.classFor(tasks).newJava('(String)', ['Olá']),
      );

      final result = await executor.run(
        testJvm.reflectMethod(tasks, 'String greet(String)'),
        ['Dart'],
        target: instance,
        convert: asString,
      );

      expect(result, 'Olá, Dart');
    });

    test(
      'the isolate keeps running while the call blocks a JVM thread',
      () async {
        final executor = start();
        final sleep = testJvm.reflectMethod(
          tasks,
          'static String sleepThenEcho(String, long)',
        );

        var ticks = 0;
        final timer = Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => ticks++,
        );
        addTearDown(timer.cancel);

        await executor.run(sleep, ['done', 500], convert: asString);

        // A direct JNI call would have frozen the event loop for the whole
        // 500 ms, and the timer would not have ticked at all.
        expect(ticks, greaterThan(20));
      },
    );

    test('runs up to `threads` calls at the same time', () async {
      final executor = start(threads: 4);
      final sleep = testJvm.reflectMethod(
        tasks,
        'static String sleepThenEcho(String, long)',
      );

      final watch = Stopwatch()..start();
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          executor.run(sleep, ['$i', 400], convert: asString),
      ]);

      expect(results, ['0', '1', '2', '3']);
      // In series: 1.6 s.
      expect(watch.elapsedMilliseconds, lessThan(1200));
    });

    test(
      'its threads are named daemons with the system class loader',
      () async {
        final executor = start(name: 'named');

        final name = await executor.run(
          testJvm.reflectMethod(tasks, 'static String threadName()'),
          [],
          convert: asString,
        );
        final loader = await executor.run(
          testJvm.reflectMethod(
            tasks,
            'static boolean hasContextClassLoader()',
          ),
          [],
          convert: (result) => result!.toDart(),
        );

        expect(name, 'named-1 daemon');
        expect(loader, isTrue);
      },
    );

    test('a Java exception fails the future with that JavaException', () async {
      final executor = start();

      await expectLater(
        executor.run(testJvm.reflectMethod(tasks, 'static void fail(String)'), [
          'on purpose',
        ], convert: (_) => null),
        throwsA(
          isA<JavaException>()
              .having(
                (e) => e.className,
                'className',
                'java.lang.IllegalStateException',
              )
              .having((e) => e.message, 'message', 'on purpose'),
        ),
      );
      expect(executor.pending, 0);
    });

    test('a void call completes with a null result', () async {
      final executor = start();
      Object? seen = 'not called';

      await executor
          .run(testJvm.reflectMethod(tasks, 'static void fail(String)'), [
            null,
          ], convert: (result) => seen = result)
          .catchError((Object _) => null);
      // `fail(null)` throws; the conversion never runs.
      expect(seen, 'not called');

      final result = await executor.run(
        testJvm.reflectMethod('java.lang.Thread', 'static void sleep(long)'),
        [1],
        convert: (result) => result,
      );
      expect(result, isNull);
    });

    test('a byte[] result comes back with asArray', () async {
      final executor = start();
      final bytes = await executor.run(
        testJvm.reflectMethod(tasks, 'static byte[] bytes(int)'),
        [5],
        convert: (result) => result!.asArray(JniType.byte).toBytes(),
      );
      expect(bytes, [0, 1, 2, 3, 4]);
    });

    test('a shared monitor serializes the calls that hold it', () async {
      final executor = start(threads: 4);
      final increment = testJvm.reflectMethod(
        tasks,
        'static int slowIncrement(long)',
      );
      final counter = testJvm.classFor(tasks);

      Future<void> round({required bool locked}) async {
        counter.setJavaStaticField('int counter', 0);
        await Future.wait([
          for (var i = 0; i < 8; i++)
            executor.run(
              increment,
              [20],
              monitor: locked ? counter : null,
              convert: (_) => null,
            ),
        ]);
      }

      await round(locked: true);
      expect(counter.getJavaStaticField('int counter'), 8);

      // The control: without the monitor, four threads read the same value.
      await round(locked: false);
      expect(counter.getJavaStaticField('int counter'), lessThan(8));
    });

    test('shutdown completes the calls that already finished', () async {
      final executor = JavaExecutor.start(testJvm, threads: 2);
      final sleep = testJvm.reflectMethod(
        tasks,
        'static String sleepThenEcho(String, long)',
      );

      final runs = [
        for (var i = 0; i < 4; i++)
          executor.run(sleep, ['$i', 100], convert: asString),
      ];

      // Blocks this isolate until the JVM threads are done; their notices are
      // still queued when it returns.
      expect(executor.shutdown(), isTrue);
      expect(await Future.wait(runs), ['0', '1', '2', '3']);
      expect(executor.isShutDown, isTrue);
    });

    test('shutdown fails a call still running past the timeout', () async {
      final executor = JavaExecutor.start(testJvm);
      final sleep = testJvm.reflectMethod(
        tasks,
        'static String sleepThenEcho(String, long)',
      );

      final run = executor.run(sleep, ['late', 2000], convert: asString);
      expect(
        executor.shutdown(timeout: const Duration(milliseconds: 50)),
        isFalse,
      );
      await expectLater(run, throwsStateError);
    });

    test('a call after shutdown is a StateError', () async {
      final executor = JavaExecutor.start(testJvm)..shutdown();
      await expectLater(
        executor.run(
          testJvm.reflectMethod(tasks, 'static String threadName()'),
          [],
          convert: asString,
        ),
        throwsStateError,
      );
    });

    test('shutdown releases the proxy machinery it was the last user of', () {
      testJvm.releaseProxyRuntime();
      final executor = JavaExecutor.start(testJvm);
      expect(testJvm.isProxyRuntimeLoaded, isTrue);

      executor.shutdown();
      expect(testJvm.isProxyRuntimeLoaded, isFalse);
    });

    test('shutdown keeps the proxy machinery while others use it', () {
      final other = testJvm.implementInterface(
        'java.lang.Runnable',
        onInvoke: (_) => null,
      );
      addTearDown(() {
        other.release();
        testJvm.releaseProxyRuntime();
      });

      JavaExecutor.start(testJvm).shutdown();
      expect(testJvm.isProxyRuntimeLoaded, isTrue);
    });

    test('threads below 1 are rejected', () {
      expect(
        () => JavaExecutor.start(testJvm, threads: 0),
        throwsArgumentError,
      );
    });
  });

  group('JavaArray.objectsFrom', () {
    test('boxes and converts each element as reflection expects', () {
      final clazz = testJvm.classFor(tasks);
      final array = autoReleaseObject(
        JavaArray.objectsFrom(testJvm, [
          true,
          7,
          1 << 40,
          1.5,
          'text',
          Uint8List.fromList([1, 2]),
          Int32List.fromList([3]),
          clazz,
          null,
        ]),
      );

      final described = clazz.callJavaStatic('String describe(Object[])', [
        array,
      ]);
      expect((described as String).split(','), [
        'java.lang.Boolean',
        'java.lang.Integer',
        'java.lang.Long',
        'java.lang.Double',
        'java.lang.String',
        '[B',
        '[I',
        'java.lang.Class',
        'null',
      ]);
    });

    test('an untyped List is ambiguous and throws', () {
      expect(
        () => JavaArray.objectsFrom(testJvm, [
          ['a', 'b'],
        ]),
        throwsA(isA<JniError>()),
      );
    });
  });

  group('asArray', () {
    test('re-types an array that came back as Object', () {
      final echoed = autoReleaseObject(
        testJvm
            .classFor('com.nfeflash.example.Fixtures')
            .callJavaStaticAs<JavaObject>('Object staticEchoObject(Object)', [
              JavaArray.ofInts(testJvm, [4, 5]),
            ]),
      );
      expect(echoed.asArray(JniType.int_).toList(), [4, 5]);
    });

    test('refuses an object that is not that array', () {
      final list = autoReleaseObject(
        testJvm.classFor('java.util.ArrayList').newJava('()'),
      );
      expect(
        () => list.asArray(JniType.byte),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            contains('java.util.ArrayList'),
          ),
        ),
      );
    });
  });
}
