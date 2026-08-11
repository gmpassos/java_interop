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

  @override
  String toString() {
    final head = message == null || message!.isEmpty
        ? 'JavaException: $className'
        : 'JavaException: $className: $message';
    if (causes.isEmpty) return head;
    return '$head\n${causes.map((c) => '  caused by: $c').join('\n')}';
  }
}
