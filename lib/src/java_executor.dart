/// Running Java calls on JVM threads, and the reflective methods they need.
library;

import 'dart:async';

import 'errors.dart';
import 'executor_class.g.dart';
import 'java_array.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'java_signature.dart';
import 'jvm.dart';
import 'jvm_class_loading.dart';
import 'jvm_diagnostics.dart';
import 'proxy.dart';
import 'signatures.dart';

/// `java.lang.reflect.Method` lookups by Java declaration.
extension JvmReflection on Jvm {
  /// The `java.lang.reflect.Method` [declaration] of [className], made
  /// accessible, as a global reference cached for this isolate.
  ///
  /// [declaration] is written as Java, like every other call in this binding:
  /// `'String greet(String)'`, `'static int add(int, int)'`. The method is
  /// looked for among [className]'s declared methods, then its superclasses',
  /// so a private, package-private or inherited method is found too.
  ///
  /// The method is made accessible from Java rather than through JNI. Since
  /// JDK 17, `setAccessible(true)` called through JNI on a thread with no Java
  /// frame is checked as if the caller were in no module, and only works for
  /// public members of public classes in exported packages — so a
  /// package-private class on the class path, which a Java caller could reach
  /// reflectively, would throw `InaccessibleObjectException` here. Members of
  /// a named module that does not open its package still cannot be made
  /// accessible; that is the module's decision, not the binding's.
  ///
  /// The result is what [JavaExecutor.run] takes. Throws a [JniError] when no
  /// such method exists. Cached methods are released by
  /// [releaseReflectedMethods].
  JavaObject reflectMethod(String className, String declaration) {
    final key = '$className#$declaration';
    final methods = _reflected[this] ??= {};
    final cached = methods[key];
    if (cached != null) return cached;

    final parsed = JavaMethod.parse(declaration);
    final name = parsed.name;
    if (name == null) {
      throw JniError(
        'no method name in "$declaration"; write it as Java does, e.g. '
        '"String greet()"',
      );
    }
    final parameters = [
      for (final type in parsed.signature.parameters)
        _classGetName(type.descriptor),
    ];

    final found = localFrame(() {
      var type = JavaObject(this, classFor(className).ref);
      while (!type.isNull) {
        final declared = type.callJavaAs<JavaArray>(
          'java.lang.reflect.Method[] getDeclaredMethods()',
        );
        for (var i = 0; i < declared.length; i++) {
          final method = declared[i] as JavaObject;
          if (method.callJavaAs<String>('String getName()') != name) continue;
          final types = method.callJavaAs<JavaArray>(
            'Class[] getParameterTypes()',
          );
          if (types.length != parameters.length) continue;
          var matches = true;
          for (var j = 0; j < types.length && matches; j++) {
            matches =
                (types[j] as JavaObject).callJavaAs<String>(
                  'String getName()',
                ) ==
                parameters[j];
          }
          if (!matches) continue;

          final accessible = _executorSupport.executorClass
              .callJavaStaticAs<JavaObject>(
                'java.lang.reflect.Method accessible(java.lang.reflect.Method)',
                [method],
              );
          return JavaObject(this, accessible.ref.toGlobal());
        }
        type = type.callJavaAs<JavaObject>('Class getSuperclass()');
      }
      return null;
    }, capacity: 64);

    if (found == null) {
      throw JniError(
        'no method $declaration in $className or its superclasses',
      );
    }
    return methods[key] = found;
  }

  /// Releases every method [reflectMethod] cached in this isolate.
  void releaseReflectedMethods() {
    final methods = _reflected[this];
    if (methods == null) return;
    for (final method in methods.values) {
      method.release();
    }
    methods.clear();
  }
}

final _reflected = Expando<Map<String, JavaObject>>('java_interop.reflected');

/// `Class.getName()` of a JNI type descriptor: `int`, `java.lang.String`,
/// `[I`, `[Ljava.lang.String;`.
String _classGetName(String descriptor) {
  if (descriptor.startsWith('[')) return descriptor.replaceAll('/', '.');
  if (descriptor.startsWith('L')) {
    return JniType.classNameToDotted(
      descriptor.substring(1, descriptor.length - 1),
    );
  }
  return switch (descriptor) {
    'Z' => 'boolean',
    'B' => 'byte',
    'C' => 'char',
    'S' => 'short',
    'I' => 'int',
    'J' => 'long',
    'F' => 'float',
    'D' => 'double',
    _ => throw JniError('not a parameter type: "$descriptor"'),
  };
}

/// The embedded `dart.jni.JavaExecutor`, defined once per isolate in a class
/// loader of its own — so isolates sharing the JVM never collide on it.
class _ExecutorSupport {
  _ExecutorSupport(this.loader, this.executorClass);

  /// Held so the class is not collected: a class lives as long as its loader.
  final JavaObject loader;
  final JavaClass executorClass;
}

final _support = Expando<_ExecutorSupport>('java_interop.executor');

extension on Jvm {
  _ExecutorSupport get _executorSupport {
    final existing = _support[this];
    if (existing != null) return existing;
    final loader = newClassLoader();
    try {
      final classes = defineClasses(loader, executorClasses);
      return _support[this] = _ExecutorSupport(
        loader,
        classes['dart.jni.JavaExecutor']!,
      );
    } catch (_) {
      loader.release();
      rethrow;
    }
  }
}

/// A pool of JVM threads that runs Java calls while the isolate goes on.
///
/// Every JNI call blocks the calling isolate until it returns. That is fine for
/// a getter and ruinous for a 30-second network call or a report render: for
/// as long as it takes, the isolate's event loop is frozen, and every other
/// request it serves waits. A [JavaExecutor] runs the call on one of its JVM
/// threads instead, and [run] returns a [Future]:
///
/// ```dart
/// final executor = JavaExecutor.start(jvm, threads: 4, name: 'reports');
/// final render = jvm.reflectMethod(
///   'com.example.Reports',
///   'static byte[] render(String)',
/// );
///
/// final pdf = await executor.run(
///   render,
///   ['monthly'],
///   convert: (result) => result!.asArray(JniType.byte).toBytes(),
/// );
/// ```
///
/// How it works: the call is submitted to a Java thread pool (an embedded
/// class, no jar), which parks the outcome under an id and tells this isolate
/// the id through a [JavaProxy] — whose `void` calls from JVM threads the
/// binding queues onto the event loop. The isolate then collects the result,
/// or has the call's own exception thrown back at it: a failed task fails
/// [run] with the same [JavaException] a direct call would have.
///
/// The calls run in parallel, up to [threads] at a time, in submission order.
/// Java code with global state is still Java code with global state: calls
/// that touch the same state should share a `monitor` (see [run]).
class JavaExecutor {
  JavaExecutor._(
    this.jvm,
    this.name,
    this.threads,
    this._executor,
    this._done,
    this._waiting,
  );

  /// Starts [threads] JVM threads named `<name>-1`, `<name>-2`, ….
  ///
  /// The threads are daemons, so they never keep the JVM up, and their context
  /// class loader is the system class loader — the one the class path is on —
  /// which JAXB, StAX, `ServiceLoader` and most frameworks look implementations
  /// up through.
  factory JavaExecutor.start(
    Jvm jvm, {
    int threads = 1,
    String name = 'java-executor',
  }) {
    if (threads < 1) {
      throw ArgumentError.value(threads, 'threads', 'must be at least 1');
    }
    final support = jvm._executorSupport;

    final waiting = <int, Completer<void>>{};
    final done = jvm.implementInterface(
      'java.util.function.LongConsumer',
      onInvoke: (call) {
        if (call.methodName == 'accept') {
          waiting.remove(call.args[0] as int)?.complete();
        }
        return null;
      },
    );

    try {
      final executor = jvm.localFrame(() {
        final local = support.executorClass.newJava(
          '(String, int, java.util.function.LongConsumer)',
          [name, threads, done.instance],
        );
        return JavaObject(jvm, local.ref.toGlobal(), support.executorClass);
      }, capacity: 16);
      return JavaExecutor._(jvm, name, threads, executor, done, waiting);
    } catch (_) {
      done.release();
      jvm.releaseProxyRuntimeIfIdle();
      rethrow;
    }
  }

  final Jvm jvm;

  /// The prefix of the threads' names.
  final String name;

  /// How many calls run at the same time.
  final int threads;

  final JavaObject _executor;
  final JavaProxy _done;

  /// The tasks submitted and not yet reported done, by id.
  final Map<int, Completer<void>> _waiting;

  bool _shutDown = false;

  /// Tasks submitted whose results have not come back yet.
  int get pending => _waiting.length;

  /// `true` once [shutdown] was called.
  bool get isShutDown => _shutDown;

  /// Runs [method] — from [JvmReflection.reflectMethod] — on a JVM thread, with
  /// [args], and completes with what [convert] makes of its result.
  ///
  /// [target] is the instance for an instance method, `null` for a static one.
  /// [args] are converted as by [JavaArray.objectsFrom]; Java holds them until
  /// the call is done, so local references are fine. When [monitor] — a
  /// [JavaObject], or a [JavaClass] for a class's own lock — is given, the JVM
  /// thread holds it for the whole call, exactly as `synchronized (monitor)`.
  ///
  /// [convert] runs on the isolate, in a local frame, once the call is done.
  /// It receives the result (`null` for `void`, a `null` return, or a
  /// primitive's box) and returns the Dart value — or a global reference, if
  /// the object outlives the frame. A Java exception from the call fails the
  /// returned future with the same [JavaException] a direct call would have
  /// thrown.
  Future<T> run<T>(
    JavaObject method,
    List<Object?> args, {
    JavaObject? target,
    Object? monitor,
    required T Function(JavaObject? result) convert,
  }) async {
    if (_shutDown) throw StateError('JavaExecutor($name) was shut down');

    final completer = Completer<void>();
    final id = jvm.localFrame(() {
      final array = JavaArray.objectsFrom(jvm, args);
      final id =
          _executor.callJava(
                'long submit(java.lang.reflect.Method, Object, Object[], Object)',
                [method, target, array, _monitorRef(monitor)],
              )
              as int;
      // In time: the notice is queued on the event loop, and runs only once
      // this synchronous code is done.
      _waiting[id] = completer;
      return id;
    }, capacity: 16 + 2 * args.length);

    _inFlight++;
    try {
      await completer.future;
      final T value = jvm.localFrame(() {
        final result = _executor.callJava('Object take(long)', [id]);
        return convert(result is JavaObject && !result.isNull ? result : null);
      }, capacity: 64);
      return value;
    } finally {
      _inFlight--;
      _releaseWhenIdle();
    }
  }

  /// [run]s between submitting and taking. The Java executor is released only
  /// once the last of them has taken its result.
  int _inFlight = 0;

  bool _released = false;

  void _releaseWhenIdle() {
    if (!_shutDown || _inFlight > 0 || _released) return;
    _released = true;
    _executor.release();
  }

  Object? _monitorRef(Object? monitor) => switch (monitor) {
    null => null,
    final JavaObject object => object,
    final JavaClass clazz => clazz.ref,
    final JavaRef ref => ref,
    _ => throw ArgumentError.value(
      monitor,
      'monitor',
      'must be a JavaObject, a JavaClass or a JavaRef',
    ),
  };

  /// Stops taking calls and waits up to [timeout] for the running ones.
  ///
  /// The wait blocks this isolate — it is meant for the end of a program or a
  /// test. Every call that finished, in time or before, still completes its
  /// [run] future with its result or its exception. Calls still running after
  /// [timeout] go on on their threads, but their [run] futures fail with a
  /// [StateError], since nothing will collect their results. Returns `true`
  /// when every call finished in time.
  ///
  /// To have *your* operations finish rather than be cut off, await them
  /// before calling this: the timeout is a last resort, not a drain.
  ///
  /// Also releases the executor's [JavaProxy] and, if it was the last proxy of
  /// this isolate, the proxy machinery — which would otherwise keep the
  /// isolate alive (see [JvmProxies.releaseProxyRuntimeIfIdle]).
  bool shutdown({Duration timeout = const Duration(seconds: 60)}) {
    if (_shutDown) return true;
    _shutDown = true;

    final finished =
        _executor.callJava('boolean shutdown(long)', [timeout.inMilliseconds])
            as bool;

    // Their notices may still be on the way through the event loop; the
    // outcome is parked, so they need none.
    for (final MapEntry(key: id, value: completer) in _waiting.entries) {
      if (_executor.callJava('boolean isDone(long)', [id]) as bool) {
        completer.complete();
      } else {
        completer.completeError(
          StateError('JavaExecutor($name) was shut down with the call running'),
        );
      }
    }
    _waiting.clear();

    _done.release();
    jvm.releaseProxyRuntimeIfIdle();
    _releaseWhenIdle();
    return finished;
  }

  @override
  String toString() => 'JavaExecutor($name, threads: $threads)';
}
