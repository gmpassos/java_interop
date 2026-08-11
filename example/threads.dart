/// Java's threads, driven from Dart.
///
/// A Dart isolate is single-threaded and a `JNIEnv*` belongs to whichever
/// thread asked for it, so there is no way to run *Dart* on a JVM thread. What
/// there is — and what this file shows — is Java's own concurrency, started and
/// observed from here, in the order worth reaching for it:
///
/// 1. **Hand Java a whole job.** `Arrays.parallelSort` uses every core and
///    calls nothing back: one JNI call in, one sorted array out. This is the
///    only shape that makes the work itself go faster.
/// 2. **Give Java a task written in Dart.** A `Runnable` implemented here does
///    *not* run on the worker: `run()` is `void`, so a call from a JVM-owned
///    thread is queued and delivered on the isolate's next turn. Four pool
///    threads still mean one Dart handler at a time.
/// 3. **A worker that wants a value back is refused**, in Java, with an
///    `IllegalStateException` naming both threads. It cannot be answered and it
///    must not hang, so it fails — visibly, and in the `Future`.
/// 4. **Shared state stays Java's**, and is guarded the way Java guards it:
///    `AtomicLong` where a single operation is enough, `jvm.synchronized` where
///    a *sequence* has to be atomic against threads this code cannot see.
/// 5. **Never block the isolate waiting for a Dart handler.** A queued call
///    runs on the event loop, so an isolate parked in `CountDownLatch.await()`
///    is waiting for something only it can do. Wait in slices instead.
///
/// One rule runs through all of it: a local reference belongs to the thread
/// that made it, and an isolate can resume on a different thread after an
/// `await`. Anything held across one is promoted with `toGlobal()` here — see
/// [_globalInstance] — and everything else is released before the `await`.
///
/// Needs no jar and no class path.
///
/// ```sh
/// dart run example/threads.dart
/// ```
library;

import 'package:java_interop/java_interop.dart';

/// Elements to sort. Large enough that dividing the work is worth it.
const _sortSize = 4000000;

Future<void> main() async {
  final Jvm jvm;
  try {
    jvm = Jvm.startOrAttach();
  } on JniError catch (e) {
    print('No JVM available:\n$e');
    return;
  }

  _javaSortsOnEveryCore(jvm);
  await _aDartRunnableOnAJavaThread(jvm);
  await _aPoolOfDartTasks(jvm);
  _stateJavaThreadsAlsoTouch(jvm);
  await _waitingWithoutBlocking(jvm);
}

/// Work that never leaves Java: the whole job goes over in one call.
///
/// `Arrays.parallelSort` splits the array across the common ForkJoin pool, so
/// every core is busy for the length of a single JNI call. Nothing is
/// converted, nothing is called back, and the isolate pays for one invocation.
void _javaSortsOnEveryCore(Jvm jvm) {
  print('--- Arrays.sort vs Arrays.parallelSort, $_sortSize longs ---');

  final runtime = jvm
      .classFor('java.lang.Runtime')
      .callJavaStaticAs<JavaObject>('java.lang.Runtime getRuntime()');
  print('processors      = ${runtime.callJava('int availableProcessors()')}');
  runtime.release();

  final commonPool = jvm
      .classFor('java.util.concurrent.ForkJoinPool')
      .callJavaStaticAs<JavaObject>(
        'java.util.concurrent.ForkJoinPool commonPool()',
      );
  final parallelism = commonPool.callJava('int getParallelism()');
  print('commonPool      = $parallelism thread(s)');
  commonPool.release();

  final arrays = jvm.classFor('java.util.Arrays');
  final oneThread = _randomLongs(jvm, _sortSize);
  final everyThread = _randomLongs(jvm, _sortSize);

  final serial = _time(
    () => arrays.callJavaStatic('void sort(long[])', [oneThread]),
  );
  final parallel = _time(
    () => arrays.callJavaStatic('void parallelSort(long[])', [everyThread]),
  );

  print('sort            ${serial.inMilliseconds} ms   one thread');
  print(
    'parallelSort    ${parallel.inMilliseconds} ms   '
    '${_ratio(serial, parallel)}x that, across $parallelism',
  );
  final identical = arrays.callJavaStatic('boolean equals(long[], long[])', [
    oneThread,
    everyThread,
  ]);
  print('same result     $identical');

  oneThread.release();
  everyThread.release();
}

/// A `Runnable` written in Dart, handed to a `java.lang.Thread`.
///
/// The Java thread runs, calls `run()`, and finishes — but the Dart handler has
/// not been entered yet. `void` from a JVM-owned thread is *queued*: Dart's
/// callbacks cannot be entered from a foreign thread, and blocking that thread
/// until the isolate answers would deadlock the moment the isolate is itself
/// inside a JNI call. So the worker returns immediately and the isolate runs
/// the handler on its next turn, which is why the thread name the handler sees
/// is its own and not the worker's.
Future<void> _aDartRunnableOnAJavaThread(Jvm jvm) async {
  print('\n--- a Dart Runnable on a java.lang.Thread ---');

  final calls = <String>[];
  final task = jvm.implementInterface(
    'java.lang.Runnable',
    handlers: {
      'run': (call) {
        calls.add('queued=${call.isQueued}, thread=${_currentThreadName(jvm)}');
        return null;
      },
    },
  );

  try {
    final thread = jvm.classFor('java.lang.Thread').newJava(
      '(java.lang.Runnable, String)',
      [task.instance, 'java-worker-1'],
    );
    thread.callJava('void start()');
    thread.callJava('void join()');
    // Released before the `await` below, since it is a local reference and the
    // isolate may come back on another thread.
    thread.release();

    print(
      'after join()    ${calls.length} handler(s) run, '
      '${jvm.queuedProxyCalls} queued',
    );

    // The turn the queued call was waiting for.
    await Future<void>.delayed(Duration.zero);

    print(
      'after one turn  ${calls.length} handler(s) run, '
      '${jvm.queuedProxyCalls} queued',
    );
    print('what it saw     ${calls.single}');
  } finally {
    task.release();
  }
}

/// A fixed pool of JVM threads, and the two things it can ask a Dart proxy for.
///
/// Four `Runnable`s and one `Callable`. The `Runnable`s are queued — the pool
/// drains in Java while the isolate is still blocked in `awaitTermination`, and
/// the handlers run one after another once it is not. The `Callable` wants a
/// value, which no JVM-owned thread can be given, so it throws in Java and the
/// `Future` hands the failure back with the reason in its cause.
Future<void> _aPoolOfDartTasks(Jvm jvm) async {
  print('\n--- a fixed thread pool, and what it can ask Dart for ---');

  final order = <int>[];
  final task = jvm.implementInterface(
    'java.lang.Runnable',
    handlers: {'run': (call) => order.add(order.length + 1)},
  );
  final answer = jvm.implementInterface(
    'java.util.concurrent.Callable',
    handlers: {'call': (call) => 42},
  );

  final pool = jvm
      .classFor('java.util.concurrent.Executors')
      .callJavaStaticAs<JavaObject>(
        'java.util.concurrent.ExecutorService newFixedThreadPool(int)',
        [4],
      );

  for (var i = 0; i < 4; i++) {
    pool.callJavaAs<JavaObject>(
      'java.util.concurrent.Future submit(java.lang.Runnable)',
      [task.instance],
    ).release();
  }

  final valued = pool.callJavaAs<JavaObject>(
    'java.util.concurrent.Future submit(java.util.concurrent.Callable)',
    [answer.instance],
  );

  // Blocks the isolate until every worker has finished — which they can, having
  // only queued their calls. Nothing here is waiting on Dart.
  pool.callJava('void shutdown()');
  final seconds = jvm
      .classFor('java.util.concurrent.TimeUnit')
      .enumConstant('SECONDS');
  final drained = pool.callJava(
    'boolean awaitTermination(long, java.util.concurrent.TimeUnit)',
    [5, seconds],
  );
  seconds.release();

  print(
    'pool drained    = $drained, with ${jvm.queuedProxyCalls} call(s) queued '
    'and ${order.length} run',
  );

  try {
    valued.callJava('Object get()');
  } on JavaException catch (e) {
    final cause = e.causes.isEmpty ? null : e.causes.first;
    print('Callable.call   ${e.className}');
    print('  caused by     ${cause?.className}');
    print('  saying        ${_firstSentence(cause?.message)}');
  }
  valued.release();
  pool.release();

  await Future<void>.delayed(Duration.zero);
  print('after one turn  handlers ran in order $order — one at a time, here');

  task.release();
  answer.release();
}

/// Guarding state that Java threads reach as well.
///
/// `AtomicLong` needs no lock: each operation is atomic in the VM, whichever
/// thread makes it. A `synchronized` collection is atomic *per method*, which
/// is not the same thing — "add it if it is not already there" is two calls,
/// and a Java thread can land between them. `jvm.synchronized` takes the very
/// lock the wrapper uses (its own monitor), so the pair becomes one indivisible
/// step for Java's threads too.
void _stateJavaThreadsAlsoTouch(Jvm jvm) {
  print('\n--- state Java threads also touch ---');

  final counter = jvm
      .classFor('java.util.concurrent.atomic.AtomicLong')
      .newJava('()');
  for (var i = 0; i < 3; i++) {
    counter.callJava('long incrementAndGet()');
  }
  print('AtomicLong      = ${counter.callJava('long get()')}');
  counter.release();

  final backing = jvm.classFor('java.util.ArrayList').newJava('()');
  final shared = jvm
      .classFor('java.util.Collections')
      .callJavaStaticAs<JavaObject>(
        'java.util.List synchronizedList(java.util.List)',
        [backing],
      );

  for (final value in ['alpha', 'beta', 'alpha']) {
    // Do not `await` inside: a monitor belongs to the OS thread that entered
    // it, and an isolate that resumes elsewhere would exit it from the wrong
    // one. That is why `synchronized` has a synchronous signature.
    jvm.synchronized(shared, () {
      final present = shared.callJava('boolean contains(Object)', [value]);
      if (present == false) {
        shared.callJava('boolean add(Object)', [value]);
      }
    });
  }

  print('shared list     = ${shared.javaToString()}');
  shared.release();
  backing.release();
}

/// Waiting for a Java thread whose work ends in a Dart handler.
///
/// The latch is counted down by the queued handler, so it is counted down *by
/// the event loop*. `latch.await()` with no timeout would therefore never
/// return: the isolate would be blocked waiting for the one thing only it can
/// do. Waiting in short slices and yielding between them costs a few
/// milliseconds and cannot deadlock — Java gets to block, Dart gets to deliver.
Future<void> _waitingWithoutBlocking(Jvm jvm) async {
  print('\n--- waiting for a Java thread without deadlocking ---');

  final latch = _globalInstance(
    jvm.classFor('java.util.concurrent.CountDownLatch'),
    '(int)',
    [1],
  );

  final worker = jvm.implementInterface(
    'java.lang.Runnable',
    handlers: {'run': (call) => latch.callJava('void countDown()')},
  );

  final thread = jvm.classFor('java.lang.Thread').newJava(
    '(java.lang.Runnable, String)',
    [worker.instance, 'latch-worker'],
  );
  thread.callJava('void start()');
  thread.callJava('void join()');
  thread.release();

  final millis = jvm
      .classFor('java.util.concurrent.TimeUnit')
      .enumConstant('MILLISECONDS');

  var polls = 0;
  var reachedZero = false;
  while (!reachedZero && polls < 100) {
    reachedZero = latch.callJavaAs<bool>(
      'boolean await(long, java.util.concurrent.TimeUnit)',
      [20, millis],
    );
    polls++;
    if (!reachedZero) await Future<void>.delayed(Duration.zero);
  }
  millis.release();

  print('count reached 0 = $reachedZero, after $polls poll(s)');
  print(
    '\nThe first poll times out because the countDown is still queued, and\n'
    'the second finds it done. That is the whole pattern: when a Java thread\n'
    'is waiting on something a Dart handler produces, the isolate has to get\n'
    'back to its event loop for the handler to exist at all.',
  );

  worker.release();
  latch.release();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Constructs an instance and promotes it to a **global** reference.
///
/// A local reference is valid on the thread that made it, and an isolate can
/// resume on a different one after an `await` — so anything used on both sides
/// of one has to be global. [type] comes from [JvmClassRegistry.classFor],
/// which is global already, and passing it also spares the object the
/// `getClass()` it would otherwise do to find its own.
JavaObject _globalInstance(
  JavaClass type,
  String declaration, [
  List<Object?> args = const [],
]) {
  final local = type.newJava(declaration, args);
  try {
    return JavaObject(local.jvm, local.ref.toGlobal(), type);
  } finally {
    local.release();
  }
}

/// `size` pseudo-random longs, as a Java `long[]` filled entirely in Java.
///
/// The seed is fixed so both sorts get the same data, and `LongStream.toArray`
/// keeps the fill on the Java side: handing over 4 million Dart ints would cost
/// more than the sort it is there to measure.
JavaArray _randomLongs(Jvm jvm, int size) {
  final random = jvm.classFor('java.util.Random').newJava('(long)', [20260811]);
  final stream = random.callJavaAs<JavaObject>(
    'java.util.stream.LongStream longs(long)',
    [size],
  );
  try {
    return stream.callJavaAs<JavaArray>('long[] toArray()');
  } finally {
    stream.release();
    random.release();
  }
}

/// The name `java.lang.Thread` gives the thread this call arrives on.
String _currentThreadName(Jvm jvm) {
  final thread = jvm
      .classFor('java.lang.Thread')
      .callJavaStaticAs<JavaObject>('java.lang.Thread currentThread()');
  try {
    return thread.callJavaAs<String>('String getName()');
  } finally {
    thread.release();
  }
}

/// The first sentence of a Java message, since these run long.
String _firstSentence(String? message) {
  if (message == null) return '(no message)';
  final stop = message.indexOf('. ');
  return stop < 0 ? message : message.substring(0, stop + 1);
}

Duration _time(void Function() body) {
  final stopwatch = Stopwatch()..start();
  body();
  return (stopwatch..stop()).elapsed;
}

/// How many times [reference] the [measured] duration is — below 1.0 on a
/// machine with one core to spare, which is an answer too.
String _ratio(Duration reference, Duration measured) =>
    (reference.inMicroseconds / measured.inMicroseconds).toStringAsFixed(1);
