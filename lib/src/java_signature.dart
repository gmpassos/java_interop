/// Building JNI descriptors from Java declarations, instead of by hand.
///
/// A descriptor like `(Ljava/lang/String;I)V` is easy to get subtly wrong, and
/// the ways it goes wrong are the worst kind: `J` is `long` and `I` is `int`,
/// `Z` is `boolean`, a class name needs `L` and a trailing `;` and slashes
/// rather than dots. None of those mistakes is caught here — they surface later
/// as a `NoSuchMethodError` from inside the VM, pointing at nothing useful.
///
/// There are two ways in, and they produce the same thing:
///
/// ```dart
/// // Write the Java, as you would read it in the source or in javap output.
/// jsig('int add(int, int)');                       // (II)I
/// jsig('String join(String[])');                   // ([Ljava/lang/String;)Ljava/lang/String;
/// jsig('void (java.io.Reader)');                   // (Ljava/io/Reader;)V
///
/// // Or build it out of types, which cannot be malformed and can be const.
/// const JSig.of([JType.int_, JType.int_], returns: JType.int_);   // (II)I
/// JType.of('java.util.List');                                    // Ljava/util/List;
/// JType.int_.array.array;                                        // [[I
/// ```
///
/// The parser is the front-end: it produces the same [JSig] the builder does.
library;

import 'errors.dart';
import 'signatures.dart';

/// A Java type, as the JNI descriptor that denotes it.
///
/// Every way of making one produces a well-formed descriptor, so the `L…;`
/// wrapper and the dots-to-slashes conversion cannot be forgotten.
class JType {
  const JType._(this.descriptor);

  /// The JNI descriptor: `I`, `Ljava/lang/String;`, `[[D`.
  final String descriptor;

  static const boolean = JType._(JniType.boolean);
  static const byte = JType._(JniType.byte);
  static const char = JType._(JniType.char);
  static const short = JType._(JniType.short);
  static const int_ = JType._(JniType.int_);
  static const long = JType._(JniType.long);
  static const float = JType._(JniType.float);
  static const double_ = JType._(JniType.double_);

  /// Only ever valid as a return type.
  static const void_ = JType._(JniType.void_);

  static const string = JType._(JniType.string);
  static const object = JType._(JniType.object);

  static const boxedBoolean = JType._('Ljava/lang/Boolean;');
  static const boxedByte = JType._('Ljava/lang/Byte;');
  static const boxedChar = JType._('Ljava/lang/Character;');
  static const boxedShort = JType._('Ljava/lang/Short;');
  static const boxedInt = JType._('Ljava/lang/Integer;');
  static const boxedLong = JType._('Ljava/lang/Long;');
  static const boxedFloat = JType._('Ljava/lang/Float;');
  static const boxedDouble = JType._('Ljava/lang/Double;');

  static const charSequence = JType._('Ljava/lang/CharSequence;');
  static const number = JType._('Ljava/lang/Number;');
  static const clazz = JType._('Ljava/lang/Class;');
  static const throwable = JType._('Ljava/lang/Throwable;');

  /// A class type by name, dotted or slashed. Nested classes keep their `$`.
  ///
  /// ```dart
  /// JType.of('java.util.List');        // Ljava/util/List;
  /// JType.of('com.example.A$Inner');   // Lcom/example/A$Inner;
  /// ```
  factory JType.of(String className) {
    if (className.isEmpty) throw JniError('empty class name');
    return JType._(JniType.objectOf(className));
  }

  /// Parses a Java type as it is written in source: `int`, `String`,
  /// `java.util.List`, `byte[]`, `int[][]`, `List<String>`.
  ///
  /// A simple (undotted) name is resolved as `java.lang.<name>`, which covers
  /// `String`, `Object`, `Integer` and the rest of the implicit import. Any
  /// other package has to be spelled out. Generic arguments are erased, exactly
  /// as javac erases them, so a declaration can be pasted in unedited.
  factory JType.parse(String source) {
    var name = _eraseGenerics(source).trim();
    if (name.isEmpty) throw JniError('empty type in a Java declaration');

    // Varargs are an array in the descriptor: `int...` is `[I`.
    var dimensions = 0;
    if (name.endsWith('...')) {
      dimensions++;
      name = name.substring(0, name.length - 3).trim();
    }
    while (name.endsWith(']')) {
      final open = name.lastIndexOf('[');
      if (open < 0 || name.substring(open + 1, name.length - 1).trim() != '') {
        throw JniError('malformed array type: "$source"');
      }
      dimensions++;
      name = name.substring(0, open).trim();
    }

    final base = _baseType(name, source);
    if (dimensions > 0 && base == void_) {
      throw JniError('there is no array of void: "$source"');
    }
    return JType._('${'[' * dimensions}${base.descriptor}');
  }

  static JType _baseType(String name, String source) {
    switch (name) {
      case 'boolean':
        return boolean;
      case 'byte':
        return byte;
      case 'char':
        return char;
      case 'short':
        return short;
      case 'int':
        return int_;
      case 'long':
        return long;
      case 'float':
        return float;
      case 'double':
        return double_;
      case 'void':
        return void_;
    }

    if (!_identifier.hasMatch(name)) {
      throw JniError('not a Java type name: "$name" (in "$source")');
    }
    // An undotted name is java.lang, the package every Java file imports.
    return JType.of(name.contains('.') ? name : 'java.lang.$name');
  }

  /// This type as an array of itself: `int` becomes `int[]`.
  JType get array => JType._('[$descriptor');

  /// `true` when this is one of the eight primitives.
  bool get isPrimitive => JniType.isPrimitive(descriptor);

  /// `true` when this is a class or array type.
  bool get isReference => JniType.isReference(descriptor);

  @override
  String toString() => descriptor;

  @override
  bool operator ==(Object other) =>
      other is JType && other.descriptor == descriptor;

  @override
  int get hashCode => descriptor.hashCode;
}

/// A Java method signature, built from [JType]s.
///
/// ```dart
/// const add = JSig.of([JType.int_, JType.int_], returns: JType.int_);
/// add.descriptor;  // (II)I
/// ```
class JSig {
  /// A method taking [parameters] and returning [returns] (`void` by default).
  const JSig.of(this.parameters, {this.returns = JType.void_});

  /// A constructor taking [parameters]. `<init>` always returns `void`.
  const JSig.ctor(this.parameters) : returns = JType.void_;

  /// Parses a Java method declaration; see [JavaMethod.parse] for the grammar.
  factory JSig.parse(String declaration) =>
      JavaMethod.parse(declaration).signature;

  final List<JType> parameters;
  final JType returns;

  /// The JNI descriptor, e.g. `(II)I`.
  String get descriptor {
    final buffer = StringBuffer('(');
    for (final parameter in parameters) {
      if (parameter == JType.void_) {
        throw JniError('"void" is not a valid parameter type');
      }
      buffer.write(parameter.descriptor);
    }
    return (buffer
          ..write(')')
          ..write(returns.descriptor))
        .toString();
  }

  @override
  String toString() => descriptor;

  @override
  bool operator ==(Object other) =>
      other is JSig && other.descriptor == descriptor;

  @override
  int get hashCode => descriptor.hashCode;
}

/// A parsed Java method declaration: the name, when one was given, and the
/// signature.
class JavaMethod {
  const JavaMethod(this.name, this.signature);

  /// The method name, or `null` for a constructor / a bare signature.
  final String? name;

  final JSig signature;

  /// The JNI descriptor of [signature].
  String get descriptor => signature.descriptor;

  /// Parses a Java method declaration.
  ///
  /// Accepts what you would read in Java source or `javap` output:
  ///
  /// ```dart
  /// JavaMethod.parse('String greet()');
  /// JavaMethod.parse('public static int add(int a, int b)');
  /// JavaMethod.parse('java.util.List<String> subList(int, int)');
  /// JavaMethod.parse('void write(byte[]) throws java.io.IOException');
  /// JavaMethod.parse('(String, int)');            // a constructor
  /// ```
  ///
  /// Modifiers, annotations, parameter names, generic arguments and a `throws`
  /// clause are all ignored, so a declaration can be pasted in unedited. The
  /// return type may be omitted only when there is nothing before the `(`, in
  /// which case this is a constructor and returns `void`.
  factory JavaMethod.parse(String declaration) =>
      _methodCache[declaration] ??= _parseMethod(declaration);

  @override
  String toString() => '${name ?? '<init>'}$descriptor';
}

/// A parsed Java field declaration: `int count`, `static String NAME`.
class JavaField {
  const JavaField(this.name, this.type);

  final String name;
  final JType type;

  /// The JNI descriptor of [type], e.g. `I`.
  String get descriptor => type.descriptor;

  /// Parses a Java field declaration, ignoring modifiers and annotations.
  ///
  /// ```dart
  /// JavaField.parse('int count');
  /// JavaField.parse('public static final String NAME');
  /// JavaField.parse('java.util.List<String> items');
  /// ```
  factory JavaField.parse(String declaration) =>
      _fieldCache[declaration] ??= _parseField(declaration);

  @override
  String toString() => '$name:$descriptor';
}

// ---------------------------------------------------------------------------
// Shorthands
// ---------------------------------------------------------------------------

/// The JNI descriptor for a Java method declaration.
///
/// ```dart
/// instance.call('greet', jsig('String greet()'));
/// ```
String jsig(String declaration) => JavaMethod.parse(declaration).descriptor;

/// The JNI descriptor for a Java type, as written in source.
///
/// ```dart
/// object.getField('count', jtype('int'));           // I
/// object.getField('names', jtype('String[]'));      // [Ljava/lang/String;
/// ```
String jtype(String typeName) => JType.parse(typeName).descriptor;

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Declarations are effectively constants at every call site, so the set of
/// distinct strings a program parses is small and fixed. Caching them keeps a
/// call in a loop from re-parsing the same text, the same way [JavaClass]
/// caches the member id it resolves from the result.
final Map<String, JavaMethod> _methodCache = {};
final Map<String, JavaField> _fieldCache = {};

final RegExp _identifier = RegExp(
  r'^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$',
);

const Set<String> _modifiers = {
  'public',
  'protected',
  'private',
  'static',
  'final',
  'abstract',
  'native',
  'synchronized',
  'transient',
  'volatile',
  'strictfp',
  'default',
};

JavaMethod _parseMethod(String declaration) {
  final source = _eraseGenerics(declaration).trim();

  final open = source.indexOf('(');
  if (open < 0) {
    throw JniError(
      'not a Java method declaration (no "("): "$declaration"\n'
      'Expected something like "int add(int, int)" or "String greet()".',
    );
  }
  final close = source.indexOf(')', open);
  if (close < 0) {
    throw JniError('not a Java method declaration (no ")"): "$declaration"');
  }

  // Everything after ')' is a throws clause or a body; neither affects the
  // descriptor.
  final head = _stripModifiers(source.substring(0, open));
  final String? name;
  final JType returns;

  if (head.isEmpty) {
    // "(String, int)" — a constructor.
    name = null;
    returns = JType.void_;
  } else if (head.length == 1) {
    // "void (String)" — a return type but no name.
    name = null;
    returns = JType.parse(head.single);
  } else {
    name = head.last;
    if (!_identifier.hasMatch(name) || name.contains('.')) {
      throw JniError('not a Java method name: "$name" (in "$declaration")');
    }
    returns = JType.parse(head.sublist(0, head.length - 1).join(' '));
  }

  final parameters = <JType>[];
  final inside = source.substring(open + 1, close).trim();
  if (inside.isNotEmpty) {
    for (final parameter in inside.split(',')) {
      final tokens = _stripModifiers(parameter);
      if (tokens.isEmpty) {
        throw JniError('empty parameter in "$declaration"');
      }
      // "int a" and "int" both give the type; a trailing name is ignored.
      final type = JType.parse(tokens.first);
      if (type == JType.void_) {
        throw JniError('"void" is not a valid parameter type: "$declaration"');
      }
      parameters.add(type);
    }
  }

  return JavaMethod(name, JSig.of(parameters, returns: returns));
}

JavaField _parseField(String declaration) {
  final tokens = _stripModifiers(_eraseGenerics(declaration));

  if (tokens.length < 2) {
    throw JniError(
      'not a Java field declaration: "$declaration"\n'
      'Expected a type and a name, like "int count".',
    );
  }

  final name = tokens.last;
  if (!_identifier.hasMatch(name) || name.contains('.')) {
    throw JniError('not a Java field name: "$name" (in "$declaration")');
  }

  final type = JType.parse(tokens.sublist(0, tokens.length - 1).join(' '));
  if (type == JType.void_) {
    throw JniError('a field cannot have type "void": "$declaration"');
  }
  return JavaField(name, type);
}

/// Splits [source] into tokens, dropping modifiers and annotations.
///
/// `int[] name` stays two tokens; `public static final int NAME` becomes
/// `[int, NAME]`.
List<String> _stripModifiers(String source) => [
  for (final token in source.split(RegExp(r'\s+')))
    if (token.isNotEmpty &&
        !token.startsWith('@') &&
        !_modifiers.contains(token))
      token,
];

/// Removes balanced `<…>` sections, the way javac erases generics.
///
/// `Map<String, List<Integer>> merge(List<String>)` becomes
/// `Map merge(List)`.
String _eraseGenerics(String source) {
  if (!source.contains('<')) return source;

  final buffer = StringBuffer();
  var depth = 0;
  for (var i = 0; i < source.length; i++) {
    final character = source[i];
    if (character == '<') {
      depth++;
    } else if (character == '>') {
      if (depth == 0) {
        throw JniError('unbalanced ">" in "$source"');
      }
      depth--;
    } else if (depth == 0) {
      buffer.write(character);
    }
  }
  if (depth != 0) throw JniError('unbalanced "<" in "$source"');
  return buffer.toString();
}
