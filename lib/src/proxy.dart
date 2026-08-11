/// Implementing Java interfaces in Dart.
///
/// A Java library that takes a listener, a visitor, a `Comparator` or any other
/// callback wants an *object* implementing an interface. Nothing in JNI creates
/// one: `Proxy.newProxyInstance` needs an `InvocationHandler`, which is a Java
/// class, and `RegisterNatives` needs a Java class to bind a native method to.
///
/// So this ships one — `java/dart/jni/DartInvocationHandler.java`, compiled into
/// [proxyClassBytes] by `tool/gen_proxy_class.dart` and loaded at runtime with
/// JNI `DefineClass`. No jar is distributed, no JDK is needed to use the
/// package, and the Java source stays readable in the repository.
///
/// ```dart
/// final ordering = jvm.implementInterface(
///   'java.util.Comparator',
///   onInvoke: (call) => switch (call.methodName) {
///     'compare' => (call.args[0] as int).compareTo(call.args[1] as int),
///     _ => null,
///   },
/// );
/// try {
///   arrays.callJavaStatic('void sort(Object[], java.util.Comparator)', [
///     values,
///     ordering.instance,
///   ]);
/// } finally {
///   ordering.release();
/// }
/// ```
///
/// ## Which thread may call
///
/// A call arriving on the isolate's own thread — the usual case, because Java is
/// only running at all since Dart called it — is dispatched synchronously and
/// can return a value. That covers visitors, comparators, `forEach` and every
/// single-abstract-method interface.
///
/// A call arriving on a thread the JVM owns (a timer, a worker pool, an SPI
/// callback) cannot be answered synchronously: Dart's `isolateLocal` callbacks
/// abort the process when invoked from another thread, and blocking that thread
/// until the isolate replies deadlocks the moment the isolate is itself inside a
/// JNI call. Such calls are therefore *queued*: a `void` method returns
/// immediately in Java and runs in Dart on the next turn of the event loop, and
/// a method with a return value throws `IllegalStateException` in Java, naming
/// both threads. Nothing here can deadlock, and nothing silently does nothing.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'boxing.dart';
import 'errors.dart';
import 'java_array.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'jvm_arrays.dart';
import 'jvm_diagnostics.dart';
import 'jvm_strings.dart';
import 'native_types.dart';
import 'proxy_class.g.dart';
import 'signatures.dart';

/// The `invokeSync` native: `(jlong token, jobject method, jobject[] args)`.
typedef _InvokeSyncC =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      Int64,
      Pointer<Void>,
      Pointer<Void>,
    );

/// The `invokeAsync` native: `(jlong token, jlong callId)`.
typedef _InvokeAsyncC =
    Void Function(Pointer<Void>, Pointer<Void>, Int64, Int64);

/// What a Dart handler is given for one call from Java.
class JavaProxyCall {
  JavaProxyCall._(
    this.proxy,
    this.methodName,
    this.method,
    this.args, {
    required this.isQueued,
  });

  /// The proxy the call arrived on.
  final JavaProxy proxy;

  /// The method's name, e.g. `compare`.
  final String methodName;

  /// The `java.lang.reflect.Method` being called, for anything [methodName] and
  /// [args] do not answer — annotations, generic types, the declaring class.
  ///
  /// **Borrowed.** It belongs to the calling Java frame; do not release it, and
  /// do not keep it past the handler unless promoted with [JavaRef.toGlobal].
  final JavaObject method;

  /// The arguments, converted: `null`, `bool`, `int`, `double`, [String] for a
  /// `java.lang.String`, and a [JavaObject] for anything else.
  ///
  /// Boxed primitives arrive unboxed, because `Proxy` hands every argument over
  /// as an `Object` and an `Integer` is almost never what a handler wants.
  /// Any [JavaObject] here is borrowed on the same terms as [method].
  final List<Object?> args;

  /// `true` when this call came from a thread the JVM owns and was queued, so
  /// the Java caller has already moved on and no return value is possible.
  final bool isQueued;

  /// The method's JNI descriptor, e.g. `(Ljava/lang/Object;)Z`.
  ///
  /// Computed on demand: it costs a JNI call per parameter, and most handlers
  /// dispatch on [methodName] alone.
  String get descriptor => _descriptor ??= _computeDescriptor();
  String? _descriptor;

  String _computeDescriptor() {
    final jvm = proxy._jvm;
    final types = method.callJavaAs<JavaArray>('Class[] getParameterTypes()');
    final parameters = StringBuffer('(');
    try {
      for (var i = 0; i < types.length; i++) {
        final type = types[i] as JavaObject;
        parameters.write(_descriptorOfClass(jvm, type));
        type.release();
      }
    } finally {
      types.release();
    }
    final returns = method.callJavaAs<JavaObject>('Class getReturnType()');
    try {
      return '$parameters)${_descriptorOfClass(jvm, returns)}';
    } finally {
      returns.release();
    }
  }

  @override
  String toString() =>
      'JavaProxyCall($methodName, ${args.length} args'
      '${isQueued ? ', queued' : ''})';
}

/// A Java object implementing interfaces in Dart.
///
/// Release it when done: it holds a global reference, a Dart handler and a
/// `NativeCallable` registration.
class JavaProxy {
  JavaProxy._(
    this._runtime,
    this.token,
    this.interfaces,
    this._instance,
    this._onInvoke,
    this._handlers,
    this._onQueuedError,
  );

  final _ProxyRuntime _runtime;

  /// Identifies this proxy's handler to the Java side. Meaningless to Java.
  final int token;

  /// The interfaces the proxy implements, as given.
  final List<String> interfaces;

  final JavaObject _instance;
  final Object? Function(JavaProxyCall call)? _onInvoke;
  final Map<String, Object? Function(JavaProxyCall call)>? _handlers;
  final void Function(Object error, StackTrace stackTrace)? _onQueuedError;

  bool _released = false;

  Jvm get _jvm => _runtime.jvm;

  /// The Java object to hand to the library that wants the interface.
  ///
  /// Owned by this proxy: pass it around, but do not release it.
  ///
  /// Reading it also re-checks which OS thread this isolate is on, which is the
  /// cheap moment to do it: handing the proxy to Java happens in the same
  /// synchronous stretch of Dart as the call that will reenter, so the thread
  /// seen here is the thread the callback will arrive on. Cache the returned
  /// object across an `await` and that stops being true — see
  /// [bindCurrentThread].
  JavaObject get instance {
    if (_released) {
      throw JniError('use of a JavaProxy after release()');
    }
    _runtime._syncOwnerThread();
    return _instance;
  }

  /// Tells Java that this isolate is now on the calling thread.
  ///
  /// Only needed when a cached [instance] is handed to Java after the isolate
  /// has moved threads — awaiting an `Isolate.run` is enough to do that, since
  /// the isolate can resume on the thread the child just freed. Reading
  /// [instance] does this automatically; this is the escape hatch for code that
  /// held onto the [JavaObject] instead.
  ///
  /// Without it, a reentrant call is *refused* with a Java exception naming both
  /// threads — never accepted wrongly, which would abort the process.
  void bindCurrentThread() {
    if (_released) {
      throw JniError('use of a JavaProxy after release()');
    }
    _runtime._rebindOwnerThread();
  }

  /// `true` once [release] has run.
  bool get isReleased => _released;

  /// Runs the handler for [call].
  Object? _dispatch(JavaProxyCall call) {
    final handler = _handlers?[call.methodName];
    if (handler != null) return handler(call);
    final fallback = _onInvoke;
    if (fallback != null) return fallback(call);
    throw JniError(
      'no handler for ${call.methodName} on a proxy of '
      '${interfaces.join(', ')}: pass onInvoke to handle the rest',
    );
  }

  /// Drops the Java object and the Dart handler.
  ///
  /// Idempotent. Calling the proxy from Java afterwards throws in Java, which is
  /// the best that can be done: the Java object may still be held by a library
  /// this code cannot reach.
  ///
  /// Releasing also lets the isolate exit. A live proxy holds it open, because a
  /// JVM thread may still queue a call to it and an exited isolate could not run
  /// it — so an isolate that forgets to release a proxy does not end.
  void release() {
    if (_released) return;
    _released = true;
    _runtime.proxies.remove(token);
    _runtime._updateIsolateAlive();
    _runtime.handlerClass.callJavaStatic('void forget(long)', [token]);
    _instance.release();
  }

  @override
  String toString() =>
      'JavaProxy(${interfaces.join(', ')}${_released ? ', released' : ''})';
}

/// Implementing Java interfaces in Dart. See the library documentation.
extension JvmProxies on Jvm {
  /// Builds a Java object implementing [interfaces], dispatching every call to
  /// Dart.
  ///
  /// Provide [handlers] keyed by method name, or [onInvoke] for everything, or
  /// both — [handlers] is consulted first. A call that matches neither throws in
  /// Java.
  ///
  /// The handler's return value is converted for the method's declared return
  /// type: `null` for `void`, a `bool`/`int`/`double` for a primitive (narrowed
  /// on the Java side, so returning `1` for a method declared `byte` is fine), a
  /// [String], a [JavaObject], or `null` for any reference.
  ///
  /// By default `toString`, `equals` and `hashCode` are answered in Java —
  /// identity equality, identity hash, and a name listing the interfaces — since
  /// a proxy that forwards those to an unprepared handler breaks the moment it
  /// reaches a `HashMap` or a log line. Pass [forwardObjectMethods] to receive
  /// them instead.
  ///
  /// [onQueuedError] receives errors thrown by a handler for a *queued* call,
  /// where there is no Java caller left to throw to. It defaults to rethrowing
  /// asynchronously, which surfaces as an unhandled isolate error rather than
  /// vanishing.
  JavaProxy implementInterfaces(
    List<String> interfaces, {
    Object? Function(JavaProxyCall call)? onInvoke,
    Map<String, Object? Function(JavaProxyCall call)>? handlers,
    bool forwardObjectMethods = false,
    void Function(Object error, StackTrace stackTrace)? onQueuedError,
  }) {
    if (interfaces.isEmpty) {
      throw JniError('implementInterfaces needs at least one interface');
    }
    if (onInvoke == null && (handlers == null || handlers.isEmpty)) {
      throw JniError('implementInterfaces needs onInvoke or handlers');
    }

    final runtime = _proxyRuntime(this);
    // Before the new handler records this thread, make sure the existing ones
    // agree with it: creating a proxy after the isolate moved threads would
    // otherwise leave the older proxies bound to a thread nothing runs on.
    runtime._syncOwnerThread();
    final token = runtime.nextToken++;

    final instance = runtime.handlerClass.callJavaStaticAs<JavaObject>(
      'Object newProxy(String[], long, boolean)',
      [
        [for (final name in interfaces) JniType.classNameToDotted(name)],
        token,
        forwardObjectMethods,
      ],
    );

    final proxy = JavaProxy._(
      runtime,
      token,
      List.unmodifiable(interfaces),
      JavaObject(this, instance.ref.toGlobal()),
      onInvoke,
      handlers == null ? null : Map.unmodifiable(handlers),
      onQueuedError,
    );
    instance.release();

    runtime.proxies[token] = proxy;
    runtime._updateIsolateAlive();
    return proxy;
  }

  /// [implementInterfaces] for the usual case of exactly one interface.
  JavaProxy implementInterface(
    String interfaceName, {
    Object? Function(JavaProxyCall call)? onInvoke,
    Map<String, Object? Function(JavaProxyCall call)>? handlers,
    bool forwardObjectMethods = false,
    void Function(Object error, StackTrace stackTrace)? onQueuedError,
  }) => implementInterfaces(
    [interfaceName],
    onInvoke: onInvoke,
    handlers: handlers,
    forwardObjectMethods: forwardObjectMethods,
    onQueuedError: onQueuedError,
  );

  /// How many proxies this isolate has built and not released.
  int get liveProxyCount => _runtimes[this]?.proxies.length ?? 0;

  /// How many queued calls are waiting for this isolate to run them.
  ///
  /// Non-zero for as long as a JVM thread has called a `void` method and the
  /// event loop has not reached it yet. Persistently non-zero means the isolate
  /// is not returning to its event loop.
  int get queuedProxyCalls {
    final runtime = _runtimes[this];
    if (runtime == null) return 0;
    return runtime.handlerClass.callJavaStatic('int pendingCount()') as int;
  }

  /// `true` once the proxy machinery has been set up in this isolate.
  bool get isProxyRuntimeLoaded => _runtimes[this] != null;

  /// Queued calls that arrived for a proxy that had already been released.
  ///
  /// Those cannot be run — the handler went with the proxy — and cannot be
  /// reported to anyone: the Java caller returned when the call was queued, and
  /// [JavaProxy.release] took the error callback with it. They are dropped, and
  /// counted here so that "a JVM thread is still calling a proxy I released" is
  /// answerable rather than invisible. A non-zero count means some Java code
  /// outlived its proxy; releasing later, or not at all, is the fix.
  int get droppedProxyCalls => _runtimes[this]?.droppedQueuedCalls ?? 0;

  /// Tears the proxy machinery down: releases every proxy, unbinds the native
  /// methods and closes the callables.
  ///
  /// Rarely needed — the runtime is meant to live as long as the isolate — but a
  /// long-lived process that is done with proxies can reclaim it, and the tests
  /// need it to prove the teardown order is safe.
  void releaseProxyRuntime() => _runtimes[this]?._dispose();
}

/// Per-isolate, per-[Jvm] proxy machinery.
///
/// An [Expando] is isolate-local, which is exactly the scope wanted: the
/// `NativeCallable`s below belong to one isolate, and a call that reached the
/// wrong isolate's callable would abort the process.
final _runtimes = Expando<_ProxyRuntime>('java_interop.proxies');

_ProxyRuntime _proxyRuntime(Jvm jvm) =>
    _runtimes[jvm] ??= _ProxyRuntime._create(jvm);

class _ProxyRuntime {
  _ProxyRuntime._(
    this.jvm,
    this.loader,
    this.handlerClass,
    this._syncCallable,
    this._asyncCallable,
  );

  final Jvm jvm;

  /// The class loader the handler class was defined in, held so it is not
  /// collected — a class lives only as long as its defining loader.
  final JavaRef loader;

  /// `dart.jni.DartInvocationHandler`, as defined by *this* isolate.
  final JavaClass handlerClass;

  final NativeCallable<_InvokeSyncC> _syncCallable;
  final NativeCallable<_InvokeAsyncC> _asyncCallable;

  final Map<int, JavaProxy> proxies = {};
  int nextToken = 1;
  bool _disposed = false;

  /// Queued calls that arrived for a proxy that had already been released.
  int droppedQueuedCalls = 0;

  /// The `JNIEnv*` this isolate was last seen on.
  ///
  /// A `JNIEnv*` is per-thread, so comparing it is a free thread-identity check:
  /// no JNI call beyond the `GetEnv` that every operation does anyway.
  Pointer<Void> _lastEnv = nullptr;

  /// Re-reads the owner thread in Java if this isolate has moved threads.
  void _syncOwnerThread() {
    final env = jvm.env;
    if (env == _lastEnv) return;
    _lastEnv = env;
    handlerClass.callJavaStatic('void rebindAll()');
  }

  /// Re-reads the owner thread unconditionally.
  void _rebindOwnerThread() {
    _lastEnv = jvm.env;
    handlerClass.callJavaStatic('void rebindAll()');
  }

  /// Holds the isolate open exactly while a proxy could still be called.
  ///
  /// A `NativeCallable` keeps its isolate alive until closed, which is right
  /// while a proxy exists — a JVM thread may queue a call, and an exited isolate
  /// could never run it — and wrong once none do: a program that has finished
  /// with its proxies should exit, not hang waiting for a callback nobody will
  /// make. So the flag follows [proxies], which makes releasing a proxy the one
  /// thing a caller has to remember, rather than releasing a proxy *and* tearing
  /// down machinery they never asked to build.
  void _updateIsolateAlive() {
    final needed = proxies.isNotEmpty;
    _syncCallable.keepIsolateAlive = needed;
    _asyncCallable.keepIsolateAlive = needed;
  }

  /// Loads the handler class into a class loader of its own and binds the two
  /// native methods to this isolate's callables.
  ///
  /// The private loader is what makes one isolate's machinery independent of
  /// another's. `RegisterNatives` binds per *class*, and two classes of the same
  /// name in different loaders are different classes — so isolate B binding its
  /// callable cannot redirect isolate A's calls into it, which would abort the
  /// process the first time A's proxy was used.
  factory _ProxyRuntime._create(Jvm jvm) {
    final loader = _newClassLoader(jvm);
    final handlerClass = _defineHandlerClass(jvm, loader);

    late final _ProxyRuntime runtime;

    final syncCallable = NativeCallable<_InvokeSyncC>.isolateLocal(
      (
        Pointer<Void> env,
        Pointer<Void> clazz,
        int token,
        Pointer<Void> method,
        Pointer<Void> args,
      ) => runtime._invokeSync(token, method, args),
    );

    final asyncCallable = NativeCallable<_InvokeAsyncC>.listener(
      (Pointer<Void> env, Pointer<Void> clazz, int token, int callId) =>
          runtime._invokeQueued(token, callId),
    );

    runtime = _ProxyRuntime._(
      jvm,
      loader,
      handlerClass,
      syncCallable,
      asyncCallable,
    );

    try {
      _bindNatives(jvm, handlerClass, syncCallable, asyncCallable);
    } catch (_) {
      syncCallable.close();
      asyncCallable.close();
      handlerClass.release();
      loader.release();
      rethrow;
    }

    // No proxies yet, so nothing to hold the isolate open for.
    runtime._updateIsolateAlive();
    return runtime;
  }

  /// Answers a reentrant call, returning the reference Java expects.
  ///
  /// Must never let a Dart error escape: a `NativeCallable` returning a pointer
  /// cannot declare an exceptional return, so an uncaught throw here aborts the
  /// process. Every failure becomes a pending Java exception instead.
  Pointer<Void> _invokeSync(
    int token,
    Pointer<Void> method,
    Pointer<Void> args,
  ) {
    try {
      // A frame of our own, so the references the handler creates on the way
      // through do not pile up in the caller's — and so the one reference worth
      // keeping is promoted into it rather than freed.
      final result = jvm.localFrameReturning(() {
        final proxy = proxies[token];
        if (proxy == null) {
          throw JniError(
            'call on a released proxy (token $token): the Java object outlived '
            'JavaProxy.release()',
          );
        }
        final call = _callFrom(proxy, method, args, isQueued: false);
        return _toJava(proxy._dispatch(call));
      }, capacity: 32);
      return result?.pointer ?? nullptr;
    } catch (error, stackTrace) {
      _raiseInJava(error, stackTrace);
      return nullptr;
    }
  }

  /// Runs a call that a JVM-owned thread queued, on the isolate's own turn.
  void _invokeQueued(int token, int callId) {
    JavaProxy? proxy;
    try {
      proxy = proxies[token];
      final taken = handlerClass.callJavaStaticAs<JavaArray>(
        'Object[] takePending(long)',
        [callId],
      );
      try {
        if (proxy == null) {
          // The proxy was released while a JVM thread still held the Java
          // object and called it. There is no handler left to run and no
          // `onQueuedError` to tell — it went with the proxy — so throwing here
          // would surface as an unhandled isolate error, killing the isolate
          // over something the caller could not have prevented. Drop it, but
          // count it: [JvmProxies.droppedProxyCalls] makes it observable
          // instead of invisible.
          droppedQueuedCalls++;
          return;
        }
        if (taken.isNull) {
          throw JniError('queued call $callId was already taken');
        }
        jvm.localFrame(() {
          final method = taken[0] as JavaObject;
          final args = taken[1] as JavaObject;
          final call = _callFrom(
            proxy!,
            method.ref.pointer,
            args.ref.pointer,
            isQueued: true,
          );
          proxy._dispatch(call);
        }, capacity: 32);
      } finally {
        taken.release();
      }
    } catch (error, stackTrace) {
      // No Java caller is left to throw to: it returned when the call was
      // queued.
      final onError = proxy?._onQueuedError;
      if (onError != null) {
        onError(error, stackTrace);
      } else {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  /// Builds a [JavaProxyCall] from the raw `Method` and `Object[]` references.
  JavaProxyCall _callFrom(
    JavaProxy proxy,
    Pointer<Void> method,
    Pointer<Void> args, {
    required bool isQueued,
  }) {
    final methodObject = JavaObject(
      jvm,
      JavaRef(jvm, method, JavaRefKind.local),
      jvm.classFor('java.lang.reflect.Method'),
    );
    final name = methodObject.callJava('String getName()') as String;

    final values = <Object?>[];
    if (args != nullptr) {
      final array = JavaRef(jvm, args, JavaRefKind.local);
      final count = jvm.arrayLength(array);
      for (var i = 0; i < count; i++) {
        values.add(_fromJava(jvm.getObjectArrayElement(array, i)));
      }
    }

    return JavaProxyCall._(
      proxy,
      name,
      methodObject,
      List.unmodifiable(values),
      isQueued: isQueued,
    );
  }

  /// Converts one argument to the natural Dart value.
  ///
  /// Ownership: the reference belongs to the Java frame, so the [JavaObject]
  /// case keeps it and the converted cases release the handle they were given.
  Object? _fromJava(JavaRef value) {
    if (value.isNull) {
      value.release();
      return null;
    }
    if (jvm.isJavaString(value)) {
      final text = jvm.stringFrom(value);
      value.release();
      return text;
    }
    final wrapper = jvm.wrapperOf(value);
    if (wrapper != null) {
      final unboxed = jvm.unboxAs(wrapper, value);
      value.release();
      return unboxed;
    }
    return JavaObject(jvm, value);
  }

  /// Converts a handler's return value to the reference `invokeSync` returns.
  ///
  /// Numbers are boxed generously — an `int` always becomes a `Long`, a `double`
  /// always a `Double` — because the Java side narrows to the declared return
  /// type. Guessing here instead would mean a `ClassCastException` from inside
  /// `Proxy` naming neither the method nor the value.
  JavaRef? _toJava(Object? value) {
    if (value == null) return null;
    if (value is JavaObject) return value.ref;
    if (value is JavaRef) return value;
    if (value is String) return jvm.newString(value);
    if (value is bool) return jvm.boxBoolean(value);
    if (value is int) return jvm.boxLong(value);
    if (value is double) return jvm.boxDouble(value);
    throw JniError(
      'a proxy handler returned ${value.runtimeType}, which has no Java '
      'equivalent: return null, a bool, int, double, String, JavaObject or '
      'JavaRef',
    );
  }

  /// Leaves [error] pending as a Java exception.
  ///
  /// A [JavaException] is re-thrown as its own class where possible, so a Java
  /// exception that passed through a Dart handler arrives at the Java caller as
  /// the type it started as, and a `catch` clause upstream still matches.
  void _raiseInJava(Object error, StackTrace stackTrace) {
    try {
      final className = error is JavaException
          ? error.className.replaceAll('.', '/')
          : 'java/lang/RuntimeException';
      final message = error is JavaException
          ? (error.message ?? error.className)
          : '$error';

      if (!_throwNew(className, message)) {
        _throwNew('java/lang/RuntimeException', 'Dart handler failed: $error');
      }
    } catch (_) {
      // Describing the failure must not become a second, worse failure. The
      // Java side sees a null return with no pending exception, which its own
      // coercion reports.
    }
  }

  /// `ThrowNew`, returning `false` rather than throwing when the class is not
  /// found or the throw is refused.
  bool _throwNew(String className, String message) {
    final env = jvm.env;
    final findClass = Jvm.fnSlotOf(
      env,
      JniFn.findClass,
    ).cast<NativeFunction<FindClassC>>().asFunction<FindClassDart>();
    final throwNew = Jvm.fnSlotOf(
      env,
      JniFn.throwNew,
    ).cast<NativeFunction<ThrowNewC>>().asFunction<ThrowNewDart>();
    final exceptionCheck = Jvm.fnSlotOf(
      env,
      JniFn.exceptionCheck,
    ).cast<NativeFunction<EnvUint8C>>().asFunction<EnvUint8Dart>();
    final exceptionClear = Jvm.fnSlotOf(
      env,
      JniFn.exceptionClear,
    ).cast<NativeFunction<EnvVoidC>>().asFunction<EnvVoidDart>();

    return using((arena) {
      final clazz = findClass(env, className.toNativeUtf8(allocator: arena));
      if (clazz == nullptr) {
        // FindClass left a NoClassDefFoundError pending; it is not the error
        // worth reporting.
        if (exceptionCheck(env) != 0) exceptionClear(env);
        return false;
      }
      final rc = throwNew(env, clazz, message.toNativeUtf8(allocator: arena));
      return rc == JniResult.ok;
    });
  }

  /// Releases everything, in the only order that is safe.
  void _dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final proxy in proxies.values.toList()) {
      proxy.release();
    }
    proxies.clear();
    handlerClass.callJavaStatic('int discardPending()');

    // Unbind *before* closing the callables. The other order leaves Java
    // holding a function pointer into freed code, and a call through it aborts
    // the process with "Callback invoked after it has been deleted" — not an
    // exception anything can catch.
    _unbindNatives(jvm, handlerClass);
    _syncCallable.close();
    _asyncCallable.close();

    handlerClass.release();
    loader.release();
    _runtimes[jvm] = null;
  }
}

/// A fresh `URLClassLoader` with no URLs, to define the handler class in.
///
/// Its parent is the system loader, so the handler can still see application
/// interfaces; it loads nothing itself, and exists only to give this isolate's
/// copy of the class a distinct identity.
JavaRef _newClassLoader(Jvm jvm) {
  final loaderClass = JavaClass.forName(jvm, 'java.net.URLClassLoader');
  try {
    final urls = JavaArray.sized(jvm, 'Ljava/net/URL;', 0);
    try {
      final loader = loaderClass.newJava('(java.net.URL[])', [urls]);
      final global = loader.ref.toGlobal();
      loader.release();
      return global;
    } finally {
      urls.release();
    }
  } finally {
    loaderClass.release();
  }
}

/// Defines `dart.jni.DartInvocationHandler` from [proxyClassBytes].
JavaClass _defineHandlerClass(Jvm jvm, JavaRef loader) {
  final env = jvm.env;
  final defineClass = Jvm.fnSlotOf(
    env,
    JniFn.defineClass,
  ).cast<NativeFunction<DefineClassC>>().asFunction<DefineClassDart>();

  final bytes = proxyClassBytes;
  final clazz = using((arena) {
    final buffer = arena<Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    return defineClass(
      env,
      proxyClassName.toNativeUtf8(allocator: arena),
      loader.pointer,
      buffer,
      bytes.length,
    );
  });

  if (clazz == nullptr) {
    jvm.checkException();
    throw JniError(
      'DefineClass($proxyClassName) failed. The class file is version '
      '55 (Java 11); a JVM older than that cannot load it.',
    );
  }

  final local = JavaRef(jvm, clazz, JavaRefKind.local);
  final global = local.toGlobal();
  local.release();
  return JavaClass(jvm, global, 'dart.jni.DartInvocationHandler');
}

/// Binds `invokeSync` and `invokeAsync` to this isolate's callables.
void _bindNatives(
  Jvm jvm,
  JavaClass handlerClass,
  NativeCallable<_InvokeSyncC> sync,
  NativeCallable<_InvokeAsyncC> async,
) {
  const entries = [
    (
      'invokeSync',
      '(JLjava/lang/reflect/Method;[Ljava/lang/Object;)Ljava/lang/Object;',
    ),
    ('invokeAsync', '(JJ)V'),
  ];
  final pointers = [
    sync.nativeFunction.cast<Void>(),
    async.nativeFunction.cast<Void>(),
  ];

  final env = jvm.env;
  final register = Jvm.fnSlotOf(
    env,
    JniFn.registerNatives,
  ).cast<NativeFunction<RegisterNativesC>>().asFunction<RegisterNativesDart>();

  final rc = using((arena) {
    final methods = arena<JniNativeMethod>(entries.length);
    for (var i = 0; i < entries.length; i++) {
      methods[i].name = entries[i].$1.toNativeUtf8(allocator: arena);
      methods[i].signature = entries[i].$2.toNativeUtf8(allocator: arena);
      methods[i].fnPtr = pointers[i];
    }
    return register(env, handlerClass.ref.pointer, methods, entries.length);
  });

  if (rc != JniResult.ok) {
    jvm.checkException();
    throw JniError('RegisterNatives on $proxyClassName failed: $rc');
  }
}

/// Unbinds every native method on the handler class.
void _unbindNatives(Jvm jvm, JavaClass handlerClass) {
  final env = jvm.env;
  final rc = Jvm.fnSlotOf(env, JniFn.unregisterNatives)
      .cast<NativeFunction<UnregisterNativesC>>()
      .asFunction<UnregisterNativesDart>()(env, handlerClass.ref.pointer);
  if (rc != JniResult.ok) {
    jvm.checkException();
    throw JniError('UnregisterNatives on $proxyClassName failed: $rc');
  }
}

/// The JNI descriptor for a `java.lang.Class`, from its name.
///
/// `Class.getName()` already returns descriptor-ish text for arrays (`[I`,
/// `[Ljava.lang.String;`) and plain names for everything else, so this is a
/// small translation rather than a type walk.
String _descriptorOfClass(Jvm jvm, JavaObject type) {
  final name = type.callJava('String getName()') as String;
  return _descriptorOfTypeName(name);
}

/// The JNI descriptor for a Java type name as `Class.getName()` reports it.
String _descriptorOfTypeName(String name) {
  const primitives = {
    'void': JniType.void_,
    'boolean': JniType.boolean,
    'byte': JniType.byte,
    'char': JniType.char,
    'short': JniType.short,
    'int': JniType.int_,
    'long': JniType.long,
    'float': JniType.float,
    'double': JniType.double_,
  };
  final primitive = primitives[name];
  if (primitive != null) return primitive;
  if (name.startsWith('[')) return name.replaceAll('.', '/');
  return 'L${name.replaceAll('.', '/')};';
}
