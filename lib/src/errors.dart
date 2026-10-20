/// Error and exception types raised by the JNI binding.
///
/// The split follows the usual Dart convention: a [JniError] means the binding
/// or its environment is misconfigured (a bug or a missing JDK), while a
/// [JavaException] is an ordinary Java-side throwable that crossed the boundary
/// and can reasonably be caught and handled.
library;

/// Thrown when the JNI layer itself cannot proceed.
///
/// Examples: `libjvm` cannot be located or loaded, `JNI_CreateJavaVM` fails,
/// the current thread cannot be attached, or a reference is used after it has
/// been released.
class JniError extends Error {
  JniError(this.message);

  final String message;

  @override
  String toString() => 'JniError: $message';
}

/// Thrown when a class, method or field cannot be resolved.
///
/// Carries the JNI name that was looked up so the message points at the exact
/// descriptor that failed, which is almost always a typo in a signature string.
class JniLookupError extends JniError {
  JniLookupError(this.kind, this.name, [this.signature])
    : super(
        signature == null
            ? 'no such $kind: $name'
            : 'no such $kind: $name$signature',
      );

  /// What was being looked up: `class`, `method`, `static method`, `field` or
  /// `static field`.
  final String kind;

  /// The JNI name of the member or class.
  final String name;

  /// The JNI type signature, when the lookup involved one.
  final String? signature;

  @override
  String toString() => 'JniLookupError: $message';
}

/// One link in a [JavaException.causes] chain.
class JavaCause {
  const JavaCause(this.className, [this.message]);

  /// Fully-qualified Java class name of the cause.
  final String className;

  /// The cause's `getMessage()`, or `null` when it carries none.
  final String? message;

  /// `true` when [className] matches, or is a subclass name ending in, [name].
  bool isA(String name) => className == name || className.endsWith('.$name');

  @override
  String toString() =>
      message == null || message!.isEmpty ? className : '$className: $message';
}

/// A Java throwable that crossed into Dart.
///
/// The Java-side exception is always *cleared* before this is thrown: JNI
/// forbids almost every call while an exception is pending, so leaving it set
/// would poison the next unrelated call with a confusing failure.
class JavaException implements Exception {
  JavaException({
    required this.className,
    required this.message,
    this.stackTraceText,
    this.causes = const [],
  });

  /// Fully-qualified Java class name, e.g. `java.lang.ArithmeticException`.
  final String className;

  /// The throwable's `getMessage()`, or `null` when it carries none.
  final String? message;

  /// The Java stack trace, when it could be captured.
  final String? stackTraceText;

  /// The `getCause()` chain, outermost first. Empty when there is none.
  ///
  /// Worth reading before deciding what a failure *means*. Libraries routinely
  /// rewrap — `catch (Exception e) { throw new Foo(e.getMessage(), e); }` — so
  /// the class that identifies the problem is often not [className] but the
  /// first or second link here. A connection timeout arriving as a
  /// library-specific exception with `java.net.SocketTimeoutException` in its
  /// cause is retryable; the same wrapper around a validation failure is not,
  /// and only the chain tells them apart.
  final List<JavaCause> causes;

  /// `true` when [className] matches, or is a subclass name ending in, [name].
  ///
  /// Accepts both `java.lang.IllegalStateException` and `IllegalStateException`
  /// so tests and call sites do not have to spell out the whole package.
  bool isA(String name) => className == name || className.endsWith('.$name');

  /// `true` when [isA] holds for this exception or for any of its [causes].
  bool isCausedBy(String name) =>
      isA(name) || causes.any((cause) => cause.isA(name));

  /// The first cause matching [name], or `null`.
  JavaCause? causeOf(String name) {
    for (final cause in causes) {
      if (cause.isA(name)) return cause;
    }
    return null;
  }

  /// The JVM errors after which the VM — and so this process, which cannot
  /// start another — should not be trusted with more work.
  ///
  /// An `OutOfMemoryError` can leave any object half-built, a
  /// `StackOverflowError` can leave a lock held or a static initializer
  /// failed for good, and an `InternalError` or `UnsatisfiedLinkError` means
  /// the VM or a native library is broken. HotSpot cannot be restarted inside a
  /// process, so the right response is for a supervisor to replace the
  /// process; [isFatal] is how to notice.
  static const fatalClassNames = {
    'java.lang.OutOfMemoryError',
    'java.lang.StackOverflowError',
    'java.lang.InternalError',
    'java.lang.UnsatisfiedLinkError',
  };

  /// `true` when this exception, or any of its [causes], is one of
  /// [fatalClassNames] — including when a library wrapped it.
  bool get isFatal =>
      fatalClassNames.contains(className) ||
      causes.any((cause) => fatalClassNames.contains(cause.className));

  /// The class a `NoClassDefFoundError` or `ClassNotFoundException` — this
  /// one or one in [causes] — says is missing, dotted; `null` otherwise.
  ///
  /// The JVM writes it in the message, sometimes slashed
  /// (`com/example/Foo`), sometimes inside a longer sentence; this is that
  /// name, which is what a "your class path lacks X" error should show.
  String? get missingClass {
    for (final (name, text) in [
      (className, message),
      for (final cause in causes) (cause.className, cause.message),
    ]) {
      if (name != 'java.lang.NoClassDefFoundError' &&
          name != 'java.lang.ClassNotFoundException') {
        continue;
      }
      final match = _qualifiedName.firstMatch(text ?? '');
      if (match != null) return match.group(1)!.replaceAll('/', '.');
    }
    return null;
  }

  static final _qualifiedName = RegExp(
    r'([a-zA-Z_$][\w$]*(?:[./][a-zA-Z_$][\w$]*)+)',
  );

  @override
  String toString() {
    final head = message == null || message!.isEmpty
        ? 'JavaException: $className'
        : 'JavaException: $className: $message';
    if (causes.isEmpty) return head;
    return '$head\n${causes.map((c) => '  caused by: $c').join('\n')}';
  }
}

/// Runs [body], turning a [JavaException] it throws into what [map] returns —
/// thrown with the original stack trace.
///
/// The one place an API translates Java failures into its own exception
/// types, instead of a `try`/`catch` in every method:
///
/// ```dart
/// String render(String id) => mapJavaExceptions(
///   () => reports.callJavaAs<String>('String render(String)', [id]),
///   (e) => ReportException(e.message ?? e.className),
/// );
/// ```
T mapJavaExceptions<T>(
  T Function() body,
  Object Function(JavaException exception) map,
) {
  try {
    return body();
  } on JavaException catch (e, stackTrace) {
    Error.throwWithStackTrace(map(e), stackTrace);
  }
}

/// [mapJavaExceptions] for an asynchronous [body], such as a
/// `JavaExecutor.run`.
Future<T> mapJavaExceptionsAsync<T>(
  Future<T> Function() body,
  Object Function(JavaException exception) map,
) async {
  try {
    return await body();
  } on JavaException catch (e, stackTrace) {
    Error.throwWithStackTrace(map(e), stackTrace);
  }
}

/// Sorts [JavaException]s into an application's own kinds by Java class name,
/// looking through the cause chain.
///
/// Libraries rewrap: `catch (Exception e) { throw new LibraryException(e); }`.
/// So the outer class is often the least informative one, and deciding on it
/// alone turns a network timeout (retry it) into a business rejection (don't).
/// A classifier walks the exception and then its [JavaException.causes], and
/// picks the first kind that is *not* one of [wrappers] — the kinds that only
/// say "the library failed". A wrapper kind is the answer only when the chain
/// holds nothing more specific.
///
/// ```dart
/// enum Failure { rejected, network, certificate }
///
/// const classifier = JavaExceptionClassifier<Failure>(
///   [
///     ('com.example.lib.ValidationException', Failure.rejected),
///     ('com.example.lib.LibraryException', Failure.rejected),
///     ('java.net.', Failure.network),
///     ('javax.net.ssl.', Failure.network),
///     ('java.security.KeyStoreException', Failure.certificate),
///   ],
///   wrappers: {Failure.rejected},
/// );
///
/// switch (classifier.classify(exception)) { … }
/// ```
///
/// A rule matches a class whose name equals its prefix or starts with it, so
/// `'java.net.'` covers a package. Rules are tried in order, so put the more
/// specific ones first.
class JavaExceptionClassifier<K extends Object> {
  const JavaExceptionClassifier(this.rules, {this.wrappers = const {}});

  /// `(class name or prefix, kind)`, tried in order.
  final List<(String, K)> rules;

  /// The kinds a more specific kind further down the cause chain overrides.
  final Set<K> wrappers;

  /// The kind of the class named [className] alone, or `null`.
  K? kindOf(String className) {
    for (final (prefix, kind) in rules) {
      if (className.startsWith(prefix)) return kind;
    }
    return null;
  }

  /// The kind of [exception], looking through its cause chain; `null` when no
  /// rule matches anything in it.
  K? classify(JavaException exception) => classifyNames([
    exception.className,
    for (final cause in exception.causes) cause.className,
  ]);

  /// [classify] over class names, outermost first — for a chain that did not
  /// come from a [JavaException].
  K? classifyNames(Iterable<String> chain) {
    K? wrapper;
    for (final name in chain) {
      final kind = kindOf(name);
      if (kind == null) continue;
      if (!wrappers.contains(kind)) return kind;
      wrapper ??= kind;
    }
    return wrapper;
  }
}
