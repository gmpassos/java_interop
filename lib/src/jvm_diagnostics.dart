/// Questions worth asking a VM before trusting it.
///
/// Every method here answers something about the *environment* rather than about
/// a particular object: which JVM is this, is the class path what I asked for,
/// is the resource my library needs actually reachable. They exist because the
/// alternative is finding out much later, from an error that names none of it.
library;

import 'dart:ffi';

import 'errors.dart';
import 'java_class.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'jvm_classes.dart';
import 'native_types.dart';

/// Classes resolved once per VM, keyed by name.
///
/// Keyed on the [Jvm] rather than static so each isolate gets its own — the same
/// shape [JvmBoxing] uses for the wrapper classes, and for the same reason: a
/// `jclass` reference belongs to the VM it came from.
final _classRegistry = Expando<Map<String, JavaClass>>('java_interop.classes');

/// A per-VM class registry.
extension JvmClassRegistry on Jvm {
  Map<String, JavaClass> get _classes =>
      _classRegistry[this] ??= <String, JavaClass>{};

  /// The [JavaClass] for [name], resolved once and reused.
  ///
  /// Prefer this over [JavaClass.forName] for any class called more than once.
  /// The member-id cache lives on the `JavaClass` *instance*, so resolving the
  /// same class twice quietly throws away every method and field id already
  /// looked up — the cache pays off only if the instance is kept, and this keeps
  /// it for you.
  ///
  /// The returned class is held as a **global** reference for the life of the
  /// process and is owned by the registry: do not [JavaClass.release] it.
  /// [releaseCachedClasses] drops them all, and [Jvm.destroy] does not need to —
  /// the VM is going away with them.
  ///
  /// ```dart
  /// // Same instance, same member-id cache, on every call.
  /// jvm.classFor('java.util.ArrayList').newJava('()');
  /// ```
  JavaClass classFor(String name) => _classes.putIfAbsent(
    name,
    () => JavaClass.forName(this, name, global: true),
  );

  /// `true` when [name] has already been resolved into the registry.
  bool isClassCached(String name) => _classes.containsKey(name);

  /// How many classes the registry holds, for tests and diagnostics.
  int get cachedClassCount => _classes.length;

  /// Releases every class the registry holds and empties it.
  ///
  /// Rarely needed — Java classes are finite and stay loaded anyway — but a
  /// process that resolves class names dynamically can use this to bound the
  /// number of global references it keeps.
  void releaseCachedClasses() {
    for (final javaClass in _classes.values) {
      javaClass.release();
    }
    _classes.clear();
  }
}

/// Environment and class-path diagnostics.
extension JvmDiagnostics on Jvm {
  /// `System.getProperty(key)`, or `null` when the property is not set.
  ///
  /// Handy for `java.version`, `java.vendor` and `java.home` when reporting what
  /// a process is actually running against.
  String? systemProperty(String key) => localFrame(() {
    final system = JavaClass.forName(this, 'java.lang.System');
    try {
      return system.callJavaStaticAs<String?>('String getProperty(String)', [
        key,
      ]);
    } finally {
      system.release();
    }
  }, capacity: 8);

  /// `true` when [path] resolves on the system class loader.
  ///
  /// [path] is a resource path, not a class name: `META-INF/services/x.Y`,
  /// `logback.xml`. Use it to check that a jar contributed the resource a
  /// library needs — service registrations in particular tend to be dropped
  /// when jars are merged into one, because the entries collide and one silently
  /// overwrites the other.
  bool resourceExists(String path) => resourceUrls(path).isNotEmpty;

  /// Every class-path URL matching the resource [path], in load order.
  ///
  /// More than one is normal and often the point: a duplicated
  /// `META-INF/services` entry is how two implementations of the same interface
  /// coexist, and *zero* when you expected one is the bug.
  List<String> resourceUrls(String path) => localFrame(() {
    final loaderClass = JavaClass.forName(this, 'java.lang.ClassLoader');
    try {
      final loader = loaderClass.callJavaStaticAs<JavaObject?>(
        'ClassLoader getSystemClassLoader()',
      );
      if (loader == null || loader.isNull) return const <String>[];

      // `getResources` returns an Enumeration<URL>; walking it is cheaper than
      // asking for a List and converting.
      final resources = loader.callJavaAs<JavaObject?>(
        'java.util.Enumeration getResources(String)',
        [path],
      );
      if (resources == null || resources.isNull) return const <String>[];

      final urls = <String>[];
      while (resources.callJavaAs<bool>('boolean hasMoreElements()')) {
        final url = resources.callJavaAs<JavaObject?>('Object nextElement()');
        if (url == null || url.isNull) break;
        final text = url.javaToString();
        if (text != null) urls.add(text);
      }
      return urls;
    } finally {
      loaderClass.release();
    }
  }, capacity: 64);

  /// Checks that every class in [classToArtifact] resolves, and says which
  /// artifact is missing when one does not.
  ///
  /// The keys are class names; the values name whatever should have provided
  /// them — a Maven coordinate, a jar name, anything a person can act on.
  ///
  /// This is for turning a late failure into an early one. A class path that is
  /// missing a transitive jar usually looks fine until the one code path that
  /// needs it runs, and the `NoClassDefFoundError` it eventually throws surfaces
  /// several frames inside a library, naming a class the caller has never heard
  /// of. Calling this at startup with the handful of classes that matter moves
  /// that discovery to the moment the class path was assembled.
  ///
  /// ```dart
  /// jvm.requireClasses({
  ///   'org.apache.axiom.om.OMAbstractFactory': 'axiom-api',
  ///   'javax.xml.bind.JAXBContext': 'javax.xml.bind:jaxb-api',
  /// });
  /// ```
  ///
  /// Throws [JniLookupError] for the first class that does not resolve, with the
  /// artifact in the message.
  void requireClasses(Map<String, String> classToArtifact) {
    for (final entry in classToArtifact.entries) {
      try {
        findClass(entry.key).release();
      } on JniLookupError {
        throw JniLookupError(
          'class',
          '${entry.key} (expected from ${entry.value})',
        );
      }
    }
  }

  /// What the VM thinks [ref] is: local, global, weak global, or nothing.
  ///
  /// The VM's own answer rather than this library's bookkeeping, which makes it
  /// the way to check a suspicion instead of confirming an assumption: a handle
  /// this package calls global but the VM calls invalid was deleted behind its
  /// back.
  ///
  /// ```dart
  /// assert(jvm.refTypeOf(cached.ref) == JavaRefTypeReport.global);
  /// ```
  JavaRefTypeReport refTypeOf(JavaRef ref) {
    if (ref.isNull) return JavaRefTypeReport.invalid;
    final env = this.env;
    final code = Jvm.fnSlotOf(env, JniFn.getObjectRefType)
        .cast<NativeFunction<GetObjectRefTypeC>>()
        .asFunction<GetObjectRefTypeDart>()(env, ref.pointer);
    return switch (code) {
      1 => JavaRefTypeReport.local,
      2 => JavaRefTypeReport.global,
      3 => JavaRefTypeReport.weakGlobal,
      _ => JavaRefTypeReport.invalid,
    };
  }
}

/// `jobjectRefType` from jni.h: what `GetObjectRefType` reports.
///
/// Distinct from [JavaRefKind], which is what this library *intends* a handle to
/// be; this is what the VM says it is.
enum JavaRefTypeReport {
  /// `JNIInvalidRefType` — not a reference the VM recognises, which includes one
  /// that has already been deleted.
  invalid,

  /// `JNILocalRefType` — belongs to the current thread and frame.
  local,

  /// `JNIGlobalRefType` — valid on any thread until deleted.
  global,

  /// `JNIWeakGlobalRefType` — global, but does not keep the object alive.
  weakGlobal,
}
