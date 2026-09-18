/// JNI type descriptors and method signatures.
///
/// JNI identifies every type by a descriptor string — `I` for `int`,
/// `Ljava/lang/String;` for a class, `[[D` for `double[][]` — and every method
/// by a signature such as `(ILjava/lang/String;)Z`. These helpers build and
/// parse those strings so call sites do not have to concatenate them by hand,
/// and so the binding can coerce Dart arguments using the declared parameter
/// types.
library;

import 'errors.dart';

/// The eight JNI primitive descriptors, plus `void`.
abstract final class JniType {
  static const boolean = 'Z';
  static const byte = 'B';
  static const char = 'C';
  static const short = 'S';
  static const int_ = 'I';
  static const long = 'J';
  static const float = 'F';
  static const double_ = 'D';
  static const void_ = 'V';

  static const string = 'Ljava/lang/String;';
  static const object = 'Ljava/lang/Object;';

  /// `Ljava/lang/String;` for `java.lang.String` or `java/lang/String`.
  static String objectOf(String className) => 'L${classNameToJni(className)};';

  /// `[I` for `I`, `[Ljava/lang/String;` for `Ljava/lang/String;`.
  static String arrayOf(String elementDescriptor) => '[$elementDescriptor';

  /// Converts a dotted Java class name to its JNI form.
  ///
  /// Accepts a name that is already in JNI form, so call sites can pass either
  /// `java.lang.String` or `java/lang/String`. Nested classes keep their `$`.
  static String classNameToJni(String className) =>
      className.replaceAll('.', '/');

  /// The inverse of [classNameToJni].
  static String classNameToDotted(String className) =>
      className.replaceAll('/', '.');

  /// `true` when [descriptor] is one of the eight primitives (not `void`).
  static bool isPrimitive(String descriptor) =>
      descriptor.length == 1 && 'ZBCSIJFD'.contains(descriptor);

  /// `true` when [descriptor] denotes a reference type (object or array).
  static bool isReference(String descriptor) =>
      descriptor.startsWith('L') || descriptor.startsWith('[');
}

/// A parsed JNI method signature.
///
/// ```dart
/// final sig = JniSignature.parse('(ILjava/lang/String;)Z');
/// sig.parameters; // ['I', 'Ljava/lang/String;']
/// sig.returnType; // 'Z'
/// ```
class JniSignature {
  JniSignature._(this.descriptor, this.parameters, this.returnType);

  /// The full signature string, e.g. `(II)I`.
  final String descriptor;

  /// The parameter descriptors, in declaration order.
  final List<String> parameters;

  /// The return descriptor, `V` for `void`.
  final String returnType;

  /// Parses a method signature, rejecting malformed input with a [JniError].
  ///
  /// Parsing is strict on purpose: a signature that is wrong in a way JNI
  /// tolerates (a missing `;`, an unknown letter) surfaces later as an
  /// unrelated `NoSuchMethodError` from the VM, which is far harder to trace
  /// back to the typo that caused it.
  factory JniSignature.parse(String descriptor) {
    if (!descriptor.startsWith('(')) {
      throw JniError('invalid signature (must start with "("): $descriptor');
    }

    final close = descriptor.indexOf(')');
    if (close < 0) {
      throw JniError('invalid signature (missing ")"): $descriptor');
    }

    final parameters = <String>[];
    var i = 1;
    while (i < close) {
      final end = _typeEnd(descriptor, i, close);
      parameters.add(descriptor.substring(i, end));
      i = end;
    }

    final returnPart = descriptor.substring(close + 1);
    if (returnPart.isEmpty) {
      throw JniError('invalid signature (missing return type): $descriptor');
    }
    if (returnPart != JniType.void_) {
      final end = _typeEnd(returnPart, 0, returnPart.length);
      if (end != returnPart.length) {
        throw JniError('invalid signature (trailing return type): $descriptor');
      }
    }

    return JniSignature._(
      descriptor,
      List.unmodifiable(parameters),
      returnPart,
    );
  }

  /// Builds a signature from [parameters] and [returns].
  ///
  /// ```dart
  /// JniSignature.of([JniType.int_, JniType.string], returns: JniType.boolean);
  /// // (ILjava/lang/String;)Z
  /// ```
  factory JniSignature.of(
    List<String> parameters, {
    String returns = JniType.void_,
  }) {
    final descriptor = '(${parameters.join()})$returns';
    // Round-trip through the parser so a malformed component is caught here
    // rather than at the VM boundary.
    return JniSignature.parse(descriptor);
  }

  /// The signature of a constructor taking [parameters] (`<init>` returns `V`).
  factory JniSignature.constructor([List<String> parameters = const []]) =>
      JniSignature.of(parameters);

  /// Index just past the type descriptor starting at [start].
  ///
  /// `V` is only ever legal as a bare return type — never as a parameter, and
  /// never as an array element — and the one bare return type is handled by
  /// [JniSignature.parse] before it gets here, so every `V` reaching this
  /// method is a malformed signature.
  static int _typeEnd(String s, int start, int limit) {
    var i = start;
    while (i < limit && s[i] == '[') {
      i++;
    }
    if (i >= limit) {
      throw JniError('invalid signature (array with no element type): $s');
    }

    final code = s[i];
    if (code == 'L') {
      final semicolon = s.indexOf(';', i);
      if (semicolon < 0 || semicolon >= limit) {
        throw JniError('invalid signature (unterminated object type): $s');
      }
      if (semicolon == i + 1) {
        throw JniError('invalid signature (empty class name): $s');
      }
      return semicolon + 1;
    }

    if (code == 'V') {
      if (i != start) {
        throw JniError('invalid signature (void array): $s');
      }
      throw JniError(
        'invalid signature ("void" is only valid as a bare return type): $s',
      );
    }

    if (!'ZBCSIJFD'.contains(code)) {
      throw JniError('invalid signature (unknown type "$code"): $s');
    }
    return i + 1;
  }

  /// The number of parameters the method declares.
  int get parameterCount => parameters.length;

  @override
  String toString() => descriptor;

  @override
  bool operator ==(Object other) =>
      other is JniSignature && other.descriptor == descriptor;

  @override
  int get hashCode => descriptor.hashCode;
}
