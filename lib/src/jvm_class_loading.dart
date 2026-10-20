/// Defining classes from bytes: Java helpers that travel inside a Dart package.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'java_array.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';
import 'signatures.dart';

/// Class loaders, and classes defined from class-file bytes.
///
/// Some things are only possible from Java — holding a monitor on another
/// thread, a thread pool, a caller-sensitive JDK API — and shipping a jar for a
/// twenty-line helper is out of proportion. Instead, compile the helper with
/// `dart run java_interop:embed_java`, which writes its class files into a Dart
/// file, and define them at runtime:
///
/// ```dart
/// final loader = jvm.newClassLoader();
/// final classes = jvm.defineClasses(loader, myHelperClasses);
/// final helper = classes['com.example.MyHelper']!;
/// ```
///
/// This is how the binding ships its own proxy handler and [JavaExecutor].
extension JvmClassLoading on Jvm {
  /// A new, empty class loader — a `java.net.URLClassLoader` with no URLs —
  /// as a global reference the caller releases.
  ///
  /// Its parent is [parent], or the system class loader: the one built from
  /// the class path given to [Jvm.startOrAttach]. A class defined in it can
  /// therefore use every class on the class path, while being distinct from
  /// any other definition of the same name — which is what lets every isolate,
  /// or every library, define its own copy without a `LinkageError`.
  ///
  /// A class lives only as long as its defining loader: keep the loader for as
  /// long as the classes are in use.
  ///
  /// A class defined here is in a *runtime package* of its own, even when its
  /// package name matches one on the class path: it can use the class path's
  /// public classes, but not their package-private members, and its
  /// superclass must be public too (`IllegalAccessError` otherwise).
  JavaObject newClassLoader({JavaObject? parent}) {
    final loaderClass = JavaClass.forName(this, 'java.net.URLClassLoader');
    try {
      final urls = JavaArray.sized(this, 'Ljava/net/URL;', 0);
      try {
        final loader = parent == null
            ? loaderClass.newJava('(java.net.URL[])', [urls])
            : loaderClass.newJava('(java.net.URL[], ClassLoader)', [
                urls,
                parent,
              ]);
        final global = loader.ref.toGlobal();
        loader.release();
        return JavaObject(this, global);
      } finally {
        urls.release();
      }
    } finally {
      loaderClass.release();
    }
  }

  /// Defines [bytes] — a class file — as [name] in [loader], returning the
  /// class as a global reference the caller releases.
  ///
  /// [name] is the binary name, dotted (`com.example.Helper$Inner`) or
  /// slashed. A class file newer than the running JVM, a name that does not
  /// match the bytes, or a name [loader] already defined, throws the JVM's
  /// error as a [JavaException] (`UnsupportedClassVersionError`,
  /// `NoClassDefFoundError`, `LinkageError`).
  JavaClass defineClass(JavaObject loader, String name, Uint8List bytes) {
    final env = this.env;
    final defineClass = Jvm.fnSlotOf(
      env,
      JniFn.defineClass,
    ).cast<NativeFunction<DefineClassC>>().asFunction<DefineClassDart>();

    final slashed = name.replaceAll('.', '/');
    final clazz = using((arena) {
      final buffer = arena<Uint8>(bytes.length);
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      return defineClass(
        env,
        slashed.toNativeUtf8(allocator: arena),
        loader.ref.pointer,
        buffer,
        bytes.length,
      );
    });

    if (clazz == nullptr) {
      checkException();
      throw JniError('DefineClass($name) failed');
    }

    final local = JavaRef(this, clazz, JavaRefKind.local);
    final global = local.toGlobal();
    local.release();
    return JavaClass(this, global, JniType.classNameToDotted(slashed));
  }

  /// Defines every class of [classes] in [loader], and returns them by name,
  /// as global references the caller releases.
  ///
  /// Any order works. The JVM resolves a class's superclass and interfaces
  /// while defining it, so one whose supertype is also in [classes] can only
  /// be defined after it — an anonymous `Foo$1` implementing `Foo$Callback`,
  /// or `Alpha extends Zeta`. A class that fails with `NoClassDefFoundError`
  /// is set aside and tried again once the others are in, until a pass makes
  /// no progress; then that error is thrown. On any failure, the classes
  /// already defined are released before the error is rethrown.
  Map<String, JavaClass> defineClasses(
    JavaObject loader,
    Map<String, Uint8List> classes,
  ) {
    final defined = <String, JavaClass>{};
    try {
      var pending = classes.entries.toList();
      while (pending.isNotEmpty) {
        final deferred = <MapEntry<String, Uint8List>>[];
        JavaException? lastFailure;
        for (final entry in pending) {
          try {
            defined[entry.key] = defineClass(loader, entry.key, entry.value);
          } on JavaException catch (e) {
            // A supertype not defined yet. Anything else is not going to get
            // better on a second try.
            if (e.className != 'java.lang.NoClassDefFoundError') rethrow;
            deferred.add(entry);
            lastFailure = e;
          }
        }
        if (deferred.length == pending.length) throw lastFailure!;
        pending = deferred;
      }
      return defined;
    } catch (_) {
      for (final clazz in defined.values) {
        clazz.release();
      }
      rethrow;
    }
  }
}
