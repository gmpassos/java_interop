/// Booting, attaching to, and talking to an embedded JVM.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'java_home.dart';
import 'jni_slots.dart';
import 'native_types.dart';

/// An embedded JVM.
///
/// A JVM is a *process-wide* singleton: `JNI_CreateJavaVM` may be called only
/// once, and HotSpot cannot recreate one after [destroy]. Dart makes that
/// awkward, because each isolate has its own statics and its own thread — and
/// `dart test` runs every suite as a separate isolate inside one process. So
/// [startOrAttach] asks `JNI_GetCreatedJavaVMs` first and only creates a VM
/// when there genuinely is not one yet.
///
/// ### Threads
///
/// `JNIEnv*` is thread-affine, and a Dart isolate is *not* pinned to an OS
/// thread — it can resume on a different one after an `await`. Caching a
/// `JNIEnv*` would therefore be a latent crash. [env] re-resolves it on every
/// access through `GetEnv`, attaching the current thread when needed, which is
/// a cheap thread-local read in the VM.
class Jvm {
  Jvm._(this.vm, this.classPath, this.options, {required this.created});

  /// The `JavaVM*` handle. Process-wide and shared by every isolate.
  final Pointer<Void> vm;

  /// The class path this VM was created with.
  ///
  /// Empty when this isolate attached to a VM that some other isolate created,
  /// because JNI offers no way to read it back. Use [isAttached] to tell that
  /// case from a VM genuinely created with an empty class path.
  final List<String> classPath;

  /// The extra VM options this VM was created with (same caveat as
  /// [classPath]).
  final List<String> options;

  /// `true` when this call created the VM, `false` when it attached to one that
  /// already existed.
  ///
  /// Worth checking whenever the class path matters. JNI cannot extend a running
  /// VM's class path, so if something else in the process booted the VM first,
  /// the [classPath] passed to [startOrAttach] was silently ignored and the
  /// classes it named are not there. Finding that out here is the difference
  /// between a clear failure at startup and a `NoClassDefFoundError` from deep
  /// inside a library much later.
  final bool created;

  /// `true` when this isolate attached to a pre-existing VM. See [created].
  bool get isAttached => !created;

  static Jvm? _instance;

  /// Cached per isolate; `DynamicLibrary.open` of the same path is cheap but
  /// not free.
  static DynamicLibrary? _libjvm;

  /// The JVM for this process, or `null` when none has been started yet *by
  /// this isolate*.
  ///
  /// Prefer [startOrAttach], which also finds a VM created by another isolate.
  static Jvm? get current => _instance;

  /// `true` when this isolate holds a handle to a running VM.
  static bool get isRunning => _instance != null;

  /// Starts a JVM, or attaches to the one this process already has.
  ///
  /// [classPath] and [vmOptions] only take effect when this call is the one
  /// that actually creates the VM. When a VM already exists they are ignored —
  /// JNI has no API to extend a running VM's class path — so every caller in a
  /// process should pass the same class path, or the first one should include
  /// everything the others need.
  ///
  /// Set [libjvmPath] to bypass [defaultLibjvmPath] discovery.
  static Jvm startOrAttach({
    String? libjvmPath,
    List<String> classPath = const [],
    List<String> vmOptions = const [],
  }) {
    final existing = _instance;
    if (existing != null) return existing;

    final library = _loadLibjvm(libjvmPath);

    final alreadyCreated = _findCreatedVm(library);
    if (alreadyCreated != null) {
      return _instance = Jvm._(
        alreadyCreated,
        const [],
        const [],
        created: false,
      );
    }

    return _instance = _create(library, classPath, vmOptions);
  }

  static DynamicLibrary _loadLibjvm(String? libjvmPath) {
    final cached = _libjvm;
    if (cached != null) return cached;

    final path = libjvmPath ?? defaultLibjvmPath();
    try {
      return _libjvm = DynamicLibrary.open(path);
    } on ArgumentError catch (e) {
      throw JniError('failed to load libjvm at "$path": ${e.message}');
    }
  }

  /// Returns the `JavaVM*` this process already has, or `null`.
  static Pointer<Void>? _findCreatedVm(DynamicLibrary library) {
    final getCreated = library
        .lookupFunction<GetCreatedJavaVmsC, GetCreatedJavaVmsDart>(
          'JNI_GetCreatedJavaVMs',
        );

    return using((arena) {
      final buffer = arena<Pointer<Void>>();
      final count = arena<Int32>();

      final rc = getCreated(buffer, 1, count);
      if (rc != JniResult.ok) {
        throw JniError(
          'JNI_GetCreatedJavaVMs failed: '
          '${JniResult.describe(rc)}',
        );
      }
      if (count.value < 1) return null;
      return buffer.value;
    });
  }

  /// How long [_awaitCreatedVm] waits for a concurrently-booting VM.
  ///
  /// Generous: a cold JVM start on a loaded machine can take seconds, and the
  /// alternative is failing a caller that merely lost a startup race.
  static const _vmStartupTimeout = Duration(seconds: 30);

  /// Polls `JNI_GetCreatedJavaVMs` until the VM another thread is booting
  /// becomes visible, or the timeout expires.
  ///
  /// Polling (rather than a condition variable) because JNI exposes no
  /// readiness signal, and this only runs on the losing side of a rare race.
  static Pointer<Void>? _awaitCreatedVm(DynamicLibrary library) {
    final deadline = DateTime.now().add(_vmStartupTimeout);

    while (DateTime.now().isBefore(deadline)) {
      final vm = _findCreatedVm(library);
      if (vm != null) return vm;
      sleep(const Duration(milliseconds: 5));
    }
    return null;
  }

  static Jvm _create(
    DynamicLibrary library,
    List<String> classPath,
    List<String> vmOptions,
  ) {
    final createVm = library.lookupFunction<CreateJavaVmC, CreateJavaVmDart>(
      'JNI_CreateJavaVM',
    );

    final allOptions = <String>[
      if (classPath.isNotEmpty)
        '-Djava.class.path=${classPath.join(classPathSeparator)}',
      ...vmOptions,
    ];

    return using((arena) {
      // The VM copies the option strings while it starts, so the arena can be
      // released as soon as JNI_CreateJavaVM returns.
      var optionArray = nullptr.cast<JavaVMOption>();
      if (allOptions.isNotEmpty) {
        optionArray = arena<JavaVMOption>(allOptions.length);
        for (var i = 0; i < allOptions.length; i++) {
          optionArray[i].optionString = allOptions[i].toNativeUtf8(
            allocator: arena,
          );
        }
      }

      final args = arena<JavaVMInitArgs>();
      args.ref
        ..version = JniVersion.v1_6
        ..nOptions = allOptions.length
        ..options = optionArray
        ..ignoreUnrecognized = 0;

      final pvm = arena<Pointer<Void>>();
      final penv = arena<Pointer<Void>>();

      final rc = createVm(pvm, penv, args.cast());

      if (rc == JniResult.exists) {
        // Lost a race: another thread began creating the VM between our
        // JNI_GetCreatedJavaVMs check and this call. Isolates starting in
        // parallel hit this routinely — `dart test` runs suites concurrently,
        // and each one is an isolate that calls startOrAttach.
        //
        // HotSpot rejects the second JNI_CreateJavaVM as soon as the first one
        // *starts*, but only publishes the VM to JNI_GetCreatedJavaVMs once it
        // has finished booting. So the handle is not available immediately —
        // wait for the winner to finish rather than failing a caller who did
        // nothing wrong.
        final raced = _awaitCreatedVm(library);
        if (raced != null) {
          return Jvm._(raced, const [], const [], created: false);
        }

        throw JniError(
          'JNI_CreateJavaVM failed: JNI_EEXIST, and the existing '
          'JVM did not become available within ${_vmStartupTimeout.inSeconds}s',
        );
      }

      if (rc != JniResult.ok) {
        throw JniError('JNI_CreateJavaVM failed: ${JniResult.describe(rc)}');
      }

      return Jvm._(
        pvm.value,
        List.unmodifiable(classPath),
        List.unmodifiable(vmOptions),
        created: true,
      );
    });
  }

  /// `JNIEnv*` for the *calling* thread, attaching it if necessary.
  ///
  /// Never cache the result across an `await`: the isolate may resume on a
  /// different OS thread, and a `JNIEnv*` from another thread is invalid.
  ///
  /// A thread attached here is also given a context class loader; see
  /// [_ensureContextClassLoader].
  Pointer<Void> get env {
    final getEnv = _vmSlot(
      JniVmFn.getEnv,
    ).cast<NativeFunction<GetEnvC>>().asFunction<GetEnvDart>();

    return using((arena) {
      final penv = arena<Pointer<Void>>();

      final rc = getEnv(vm, penv, JniVersion.v1_6);
      if (rc == JniResult.ok) return penv.value;

      if (rc == JniResult.detached) {
        final attach = _vmSlot(
          JniVmFn.attachCurrentThread,
        ).cast<NativeFunction<AttachThreadC>>().asFunction<AttachThreadDart>();

        final attachRc = attach(vm, penv, nullptr);
        if (attachRc != JniResult.ok) {
          throw JniError(
            'AttachCurrentThread failed: '
            '${JniResult.describe(attachRc)}',
          );
        }
        _ensureContextClassLoader(penv.value);
        return penv.value;
      }

      throw JniError('GetEnv failed: ${JniResult.describe(rc)}');
    });
  }

  /// Gives a thread this binding just attached the system class loader as its
  /// context class loader.
  ///
  /// `AttachCurrentThread` hands the new `java.lang.Thread` a **null** context
  /// class loader, while the thread that created the VM gets the application
  /// one. Everything that discovers implementations through the context loader
  /// — `ServiceLoader`, JAXB, StAX, JAXP, and anything that calls
  /// `getResources` on it — then behaves differently depending on *which*
  /// thread served the call. Because a Dart isolate can resume on any thread of
  /// the pool, that difference is intermittent, which is the worst way to find
  /// it: Axis2, for one, dereferences the loader unguarded and logs a
  /// `NullPointerException` over it on some calls and not others.
  ///
  /// Only a *null* loader is filled in. A loader set deliberately on this
  /// thread — including by the JVM, on the thread that created it — is left
  /// alone; this is a default, not a policy.
  ///
  /// Raw JNI throughout, because the higher-level API reads [env], which is
  /// still being resolved here. It never throws and never leaves an exception
  /// pending: a thread without a context class loader is worse than one with,
  /// but failing the attach over it would be worse still.
  void _ensureContextClassLoader(Pointer<Void> envPointer) {
    var thread = nullptr as Pointer<Void>;
    var threadClass = nullptr as Pointer<Void>;
    var loaderClass = nullptr as Pointer<Void>;
    var loader = nullptr as Pointer<Void>;

    try {
      threadClass = _rawFindClass(envPointer, 'java/lang/Thread');
      if (threadClass == nullptr) return;

      final currentThread = _rawStaticMethodId(
        envPointer,
        threadClass,
        'currentThread',
        '()Ljava/lang/Thread;',
      );
      final getContextClassLoader = _rawMethodId(
        envPointer,
        threadClass,
        'getContextClassLoader',
        '()Ljava/lang/ClassLoader;',
      );
      final setContextClassLoader = _rawMethodId(
        envPointer,
        threadClass,
        'setContextClassLoader',
        '(Ljava/lang/ClassLoader;)V',
      );
      if (currentThread == nullptr ||
          getContextClassLoader == nullptr ||
          setContextClassLoader == nullptr) {
        return;
      }

      thread = _rawCallStaticObject(envPointer, threadClass, currentThread);
      if (thread == nullptr) return;

      final existing = _rawCallObject(
        envPointer,
        thread,
        getContextClassLoader,
      );
      if (existing != nullptr) {
        // Already has one — the thread that created the VM, or a loader someone
        // chose. Nothing to do.
        _rawDeleteLocalRef(envPointer, existing);
        return;
      }

      loaderClass = _rawFindClass(envPointer, 'java/lang/ClassLoader');
      if (loaderClass == nullptr) return;

      final getSystemClassLoader = _rawStaticMethodId(
        envPointer,
        loaderClass,
        'getSystemClassLoader',
        '()Ljava/lang/ClassLoader;',
      );
      if (getSystemClassLoader == nullptr) return;

      loader = _rawCallStaticObject(
        envPointer,
        loaderClass,
        getSystemClassLoader,
      );
      if (loader == nullptr) return;

      _rawCallVoidWithObject(envPointer, thread, setContextClassLoader, loader);
    } on Object {
      // Deliberately swallowed: see the doc comment.
    } finally {
      _rawDeleteLocalRef(envPointer, loader);
      _rawDeleteLocalRef(envPointer, loaderClass);
      _rawDeleteLocalRef(envPointer, thread);
      _rawDeleteLocalRef(envPointer, threadClass);
      _rawClearException(envPointer);
    }
  }

  /// Detaches the calling thread from the VM.
  ///
  /// Only needed for threads this binding attached implicitly and that are
  /// about to die. Detaching the thread that created the VM is not allowed.
  void detachCurrentThread() {
    final detach = _vmSlot(
      JniVmFn.detachCurrentThread,
    ).cast<NativeFunction<VmIntC>>().asFunction<VmIntDart>();

    final rc = detach(vm);
    if (rc != JniResult.ok) {
      throw JniError('DetachCurrentThread failed: ${JniResult.describe(rc)}');
    }
  }

  /// The JNI version the VM reports, e.g. `0x00150000` for JNI 21.
  int get version {
    final fn = fnSlot(
      JniFn.getVersion,
    ).cast<NativeFunction<EnvIntC>>().asFunction<EnvIntDart>();
    return fn(env);
  }

  /// Reads slot [index] out of the `JNIEnv` function table.
  ///
  /// The escape hatch for JNI functions this binding does not wrap: look the
  /// slot up in `jni.h`, cast it to the right `NativeFunction`, and call it.
  Pointer<Void> fnSlot(int index) =>
      env.cast<Pointer<Pointer<Void>>>().value[index];

  /// Like [fnSlot], but resolved against an already-fetched [envPointer].
  ///
  /// Used when several calls happen back-to-back and re-resolving [env] each
  /// time would be wasteful — safe as long as no `await` intervenes.
  static Pointer<Void> fnSlotOf(Pointer<Void> envPointer, int index) =>
      envPointer.cast<Pointer<Pointer<Void>>>().value[index];

  Pointer<Void> _vmSlot(int index) =>
      vm.cast<Pointer<Pointer<Void>>>().value[index];

  /// Shuts the VM down.
  ///
  /// Terminal for the whole process: HotSpot cannot start a second VM
  /// afterwards, so a test suite or long-running app should simply let the VM
  /// live until exit. Provided for completeness and for the single-shot CLI
  /// case.
  void destroy() {
    final fn = _vmSlot(
      JniVmFn.destroyJavaVm,
    ).cast<NativeFunction<VmIntC>>().asFunction<VmIntDart>();

    final rc = fn(vm);
    if (rc != JniResult.ok) {
      throw JniError('DestroyJavaVM failed: ${JniResult.describe(rc)}');
    }
    if (identical(_instance, this)) _instance = null;
  }

  // -------------------------------------------------------------------------
  // Exceptions
  // -------------------------------------------------------------------------

  /// Guards against re-entering exception description while describing one.
  static bool _describing = false;

  /// Throws a [JavaException] when a Java exception is pending, otherwise
  /// returns.
  ///
  /// Called after every JNI operation that can raise. The pending exception is
  /// always cleared first: JNI forbids nearly every call while one is set, so
  /// the description below would itself fail.
  void checkException() {
    final envPointer = env;

    final check = fnSlotOf(
      envPointer,
      JniFn.exceptionCheck,
    ).cast<NativeFunction<EnvUint8C>>().asFunction<EnvUint8Dart>();
    if (check(envPointer) == 0) return;

    final occurred = fnSlotOf(
      envPointer,
      JniFn.exceptionOccurred,
    ).cast<NativeFunction<EnvObjectC>>().asFunction<EnvObjectDart>();
    final clear = fnSlotOf(
      envPointer,
      JniFn.exceptionClear,
    ).cast<NativeFunction<EnvVoidC>>().asFunction<EnvVoidDart>();

    final throwable = occurred(envPointer);
    clear(envPointer);

    if (throwable == nullptr) {
      throw JavaException(
        className: 'java.lang.Throwable',
        message: 'unknown Java exception',
      );
    }

    if (_describing) {
      // Describing an exception raised another one. Do not recurse.
      _rawDeleteLocalRef(envPointer, throwable);
      throw JavaException(
        className: 'java.lang.Throwable',
        message: 'a Java exception was raised while describing another',
      );
    }

    _describing = true;
    try {
      throw _describe(envPointer, throwable);
    } finally {
      _describing = false;
      _rawDeleteLocalRef(envPointer, throwable);
    }
  }

  /// Builds a [JavaException] from a pending-and-now-cleared throwable.
  ///
  /// Every step is best-effort: a failure to read the message must not replace
  /// the real exception with a less useful one.
  JavaException _describe(Pointer<Void> envPointer, Pointer<Void> throwable) {
    var className = 'java.lang.Throwable';
    String? message;
    String? stackTraceText;
    var causes = const <JavaCause>[];

    try {
      final throwableClass = _rawFindClass(envPointer, 'java/lang/Throwable');
      final classClass = _rawFindClass(envPointer, 'java/lang/Class');

      final getClass = _rawMethodId(
        envPointer,
        throwableClass,
        'getClass',
        '()Ljava/lang/Class;',
      );
      final getName = _rawMethodId(
        envPointer,
        classClass,
        'getName',
        '()Ljava/lang/String;',
      );
      final getMessage = _rawMethodId(
        envPointer,
        throwableClass,
        'getMessage',
        '()Ljava/lang/String;',
      );

      className =
          _rawClassNameOf(envPointer, throwable, getClass, getName) ??
          className;

      if (getMessage != nullptr) {
        final messageString = _rawCallObject(envPointer, throwable, getMessage);
        message = _rawStringFrom(envPointer, messageString);
        _rawDeleteLocalRef(envPointer, messageString);
      }

      stackTraceText = _rawStackTrace(envPointer, throwable, throwableClass);

      causes = _rawCauses(
        envPointer,
        throwable,
        throwableClass,
        getClass,
        getName,
        getMessage,
      );

      _rawDeleteLocalRef(envPointer, classClass);
      _rawDeleteLocalRef(envPointer, throwableClass);
    } on Object {
      // Keep whatever was gathered.
    }

    // Any exception raised while describing must not stay pending.
    _rawClearException(envPointer);

    return JavaException(
      className: className,
      message: message,
      stackTraceText: stackTraceText,
      causes: causes,
    );
  }

  /// How far [_rawCauses] follows `getCause()`.
  ///
  /// A bound rather than a limit anyone should hit: real chains are two or three
  /// deep. It is what keeps a self-referential or cyclic chain — which
  /// `initCause` forbids but `Throwable` subclasses can still build by
  /// overriding `getCause()` — from spinning here while an exception is pending.
  static const _maxCauseDepth = 8;

  /// Walks the `getCause()` chain, outermost first.
  ///
  /// Uses only the raw helpers, because this runs while describing a throwable
  /// that has already been cleared: any checked call would re-enter
  /// [checkException].
  List<JavaCause> _rawCauses(
    Pointer<Void> envPointer,
    Pointer<Void> throwable,
    Pointer<Void> throwableClass,
    Pointer<Void> getClass,
    Pointer<Void> getName,
    Pointer<Void> getMessage,
  ) {
    final getCause = _rawMethodId(
      envPointer,
      throwableClass,
      'getCause',
      '()Ljava/lang/Throwable;',
    );
    if (getCause == nullptr) return const [];

    final causes = <JavaCause>[];
    final seen = <Pointer<Void>>[throwable];
    var current = throwable;

    try {
      for (var depth = 0; depth < _maxCauseDepth; depth++) {
        final cause = _rawCallObject(envPointer, current, getCause);
        if (cause == nullptr) break;

        // A throwable whose cause is itself, or an earlier link, is a cycle.
        if (seen.any((other) => _rawIsSameObject(envPointer, other, cause))) {
          _rawDeleteLocalRef(envPointer, cause);
          break;
        }

        final causeClass =
            _rawClassNameOf(envPointer, cause, getClass, getName) ??
            'java.lang.Throwable';

        String? causeMessage;
        if (getMessage != nullptr) {
          final messageString = _rawCallObject(envPointer, cause, getMessage);
          causeMessage = _rawStringFrom(envPointer, messageString);
          _rawDeleteLocalRef(envPointer, messageString);
        }

        causes.add(JavaCause(causeClass, causeMessage));
        seen.add(cause);
        current = cause;
      }
    } on Object {
      // Keep whatever was gathered.
    } finally {
      // `seen[0]` is the throwable itself, owned by the caller.
      for (var i = 1; i < seen.length; i++) {
        _rawDeleteLocalRef(envPointer, seen[i]);
      }
    }

    return causes;
  }

  /// `object.getClass().getName()`, or `null` when either call fails.
  String? _rawClassNameOf(
    Pointer<Void> envPointer,
    Pointer<Void> object,
    Pointer<Void> getClass,
    Pointer<Void> getName,
  ) {
    if (getClass == nullptr || getName == nullptr) return null;

    final actualClass = _rawCallObject(envPointer, object, getClass);
    if (actualClass == nullptr) return null;

    final nameString = _rawCallObject(envPointer, actualClass, getName);
    final name = _rawStringFrom(envPointer, nameString);

    _rawDeleteLocalRef(envPointer, nameString);
    _rawDeleteLocalRef(envPointer, actualClass);
    return name;
  }

  /// `throwable.printStackTrace(new PrintWriter(new StringWriter()))`.
  String? _rawStackTrace(
    Pointer<Void> envPointer,
    Pointer<Void> throwable,
    Pointer<Void> throwableClass,
  ) {
    try {
      final stringWriterClass = _rawFindClass(
        envPointer,
        'java/io/StringWriter',
      );
      final printWriterClass = _rawFindClass(envPointer, 'java/io/PrintWriter');
      if (stringWriterClass == nullptr || printWriterClass == nullptr) {
        return null;
      }

      final newStringWriter = _rawMethodId(
        envPointer,
        stringWriterClass,
        '<init>',
        '()V',
      );
      final newPrintWriter = _rawMethodId(
        envPointer,
        printWriterClass,
        '<init>',
        '(Ljava/io/Writer;)V',
      );
      final printStackTrace = _rawMethodId(
        envPointer,
        throwableClass,
        'printStackTrace',
        '(Ljava/io/PrintWriter;)V',
      );
      final toStringId = _rawMethodId(
        envPointer,
        stringWriterClass,
        'toString',
        '()Ljava/lang/String;',
      );

      if (newStringWriter == nullptr ||
          newPrintWriter == nullptr ||
          printStackTrace == nullptr ||
          toStringId == nullptr) {
        return null;
      }

      final newObject = fnSlotOf(
        envPointer,
        JniFn.newObjectA,
      ).cast<NativeFunction<CallObjectAC>>().asFunction<CallObjectADart>();

      final writer = newObject(
        envPointer,
        stringWriterClass,
        newStringWriter,
        nullptr,
      );
      if (writer == nullptr) return null;

      return using((arena) {
        final args = arena<Int64>(1);
        args[0] = writer.address;

        final printWriter = newObject(
          envPointer,
          printWriterClass,
          newPrintWriter,
          args,
        );
        if (printWriter == nullptr) {
          _rawDeleteLocalRef(envPointer, writer);
          return null;
        }

        final callVoid = fnSlotOf(
          envPointer,
          JniFn.callVoidMethodA,
        ).cast<NativeFunction<CallVoidAC>>().asFunction<CallVoidADart>();

        final printArgs = arena<Int64>(1);
        printArgs[0] = printWriter.address;
        callVoid(envPointer, throwable, printStackTrace, printArgs);

        final text = _rawCallObject(envPointer, writer, toStringId);
        final result = _rawStringFrom(envPointer, text);

        _rawDeleteLocalRef(envPointer, text);
        _rawDeleteLocalRef(envPointer, printWriter);
        _rawDeleteLocalRef(envPointer, writer);
        return result;
      });
    } on Object {
      return null;
    }
  }

  // --- Raw helpers: no exception checking, so they are safe to use *while*
  // --- describing a pending exception.

  Pointer<Void> _rawFindClass(Pointer<Void> envPointer, String name) {
    final fn = fnSlotOf(
      envPointer,
      JniFn.findClass,
    ).cast<NativeFunction<FindClassC>>().asFunction<FindClassDart>();
    return using(
      (arena) => fn(envPointer, name.toNativeUtf8(allocator: arena)),
    );
  }

  Pointer<Void> _rawMethodId(
    Pointer<Void> envPointer,
    Pointer<Void> clazz,
    String name,
    String signature,
  ) {
    if (clazz == nullptr) return nullptr;
    final fn = fnSlotOf(
      envPointer,
      JniFn.getMethodId,
    ).cast<NativeFunction<MemberIdC>>().asFunction<MemberIdDart>();
    return using(
      (arena) => fn(
        envPointer,
        clazz,
        name.toNativeUtf8(allocator: arena),
        signature.toNativeUtf8(allocator: arena),
      ),
    );
  }

  Pointer<Void> _rawStaticMethodId(
    Pointer<Void> envPointer,
    Pointer<Void> clazz,
    String name,
    String signature,
  ) {
    if (clazz == nullptr) return nullptr;
    final fn = fnSlotOf(
      envPointer,
      JniFn.getStaticMethodId,
    ).cast<NativeFunction<MemberIdC>>().asFunction<MemberIdDart>();
    return using(
      (arena) => fn(
        envPointer,
        clazz,
        name.toNativeUtf8(allocator: arena),
        signature.toNativeUtf8(allocator: arena),
      ),
    );
  }

  Pointer<Void> _rawCallStaticObject(
    Pointer<Void> envPointer,
    Pointer<Void> clazz,
    Pointer<Void> method,
  ) {
    final fn = fnSlotOf(
      envPointer,
      JniFn.callStaticObjectMethodA,
    ).cast<NativeFunction<CallObjectAC>>().asFunction<CallObjectADart>();
    return fn(envPointer, clazz, method, nullptr);
  }

  /// A `void` call taking a single object argument, staged through a one-slot
  /// `jvalue[]`.
  void _rawCallVoidWithObject(
    Pointer<Void> envPointer,
    Pointer<Void> receiver,
    Pointer<Void> method,
    Pointer<Void> argument,
  ) {
    final fn = fnSlotOf(
      envPointer,
      JniFn.callVoidMethodA,
    ).cast<NativeFunction<CallVoidAC>>().asFunction<CallVoidADart>();
    using((arena) {
      final args = arena<Int64>();
      args.value = argument.address;
      fn(envPointer, receiver, method, args);
    });
  }

  Pointer<Void> _rawCallObject(
    Pointer<Void> envPointer,
    Pointer<Void> receiver,
    Pointer<Void> method,
  ) {
    final fn = fnSlotOf(
      envPointer,
      JniFn.callObjectMethodA,
    ).cast<NativeFunction<CallObjectAC>>().asFunction<CallObjectADart>();
    return fn(envPointer, receiver, method, nullptr);
  }

  String? _rawStringFrom(Pointer<Void> envPointer, Pointer<Void> string) {
    if (string == nullptr) return null;

    final getLength = fnSlotOf(envPointer, JniFn.getStringLength)
        .cast<NativeFunction<GetStringLengthC>>()
        .asFunction<GetStringLengthDart>();
    final getChars = fnSlotOf(
      envPointer,
      JniFn.getStringChars,
    ).cast<NativeFunction<GetStringCharsC>>().asFunction<GetStringCharsDart>();
    final releaseChars = fnSlotOf(envPointer, JniFn.releaseStringChars)
        .cast<NativeFunction<ReleaseStringCharsC>>()
        .asFunction<ReleaseStringCharsDart>();

    final length = getLength(envPointer, string);
    final chars = getChars(envPointer, string, nullptr);
    if (chars == nullptr) return null;
    try {
      return String.fromCharCodes(chars.asTypedList(length));
    } finally {
      releaseChars(envPointer, string, chars);
    }
  }

  void _rawDeleteLocalRef(Pointer<Void> envPointer, Pointer<Void> reference) {
    if (reference == nullptr) return;
    fnSlotOf(envPointer, JniFn.deleteLocalRef)
        .cast<NativeFunction<DeleteRefC>>()
        .asFunction<DeleteRefDart>()(envPointer, reference);
  }

  bool _rawIsSameObject(
    Pointer<Void> envPointer,
    Pointer<Void> a,
    Pointer<Void> b,
  ) {
    final fn = fnSlotOf(
      envPointer,
      JniFn.isSameObject,
    ).cast<NativeFunction<IsSameObjectC>>().asFunction<IsSameObjectDart>();
    return fn(envPointer, a, b) != 0;
  }

  void _rawClearException(Pointer<Void> envPointer) {
    final check = fnSlotOf(
      envPointer,
      JniFn.exceptionCheck,
    ).cast<NativeFunction<EnvUint8C>>().asFunction<EnvUint8Dart>();
    if (check(envPointer) == 0) return;
    fnSlotOf(
      envPointer,
      JniFn.exceptionClear,
    ).cast<NativeFunction<EnvVoidC>>().asFunction<EnvVoidDart>()(envPointer);
  }

  @override
  String toString() =>
      'Jvm(0x${vm.address.toRadixString(16)}, '
      'classPath: ${classPath.length}, options: ${options.length})';
}

/// The class-path *list* separator: `;` on Windows, `:` elsewhere.
///
/// Not `Platform.pathSeparator`, which is the separator *within* a path (`\`
/// or `/`) — a classic mix-up that produces a class path the VM silently reads
/// as one long nonexistent entry.
String get classPathSeparator => Platform.isWindows ? ';' : ':';
