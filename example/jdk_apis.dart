/// Doing real work with the JDK — the reason to embed a JVM at all.
///
/// Every other example here calls the test fixtures. This one calls libraries
/// that ship with every JDK and have no equally batteries-included equivalent
/// in Dart: a locale database, a compression codec, a crypto provider.
///
/// Needs no jar and no class path — these classes are already on the
/// bootstrap loader.
///
/// ```sh
/// dart run example/jdk_apis.dart
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:java_interop/java_interop.dart';

void main() {
  final Jvm jvm;
  try {
    jvm = Jvm.startOrAttach();
  } on JniError catch (e) {
    print('No JVM available:\n$e');
    return;
  }

  _digest(jvm);
  _localeAwareFormatting(jvm);
  _compression(jvm);
}

/// SHA-256 through `java.security.MessageDigest`.
///
/// A `byte[]` in each direction: the Dart `List<int>` is converted to a Java
/// array on the way in, and the digest comes back as a [JavaArray] that reads
/// out as an [Int8List].
void _digest(Jvm jvm) {
  print('--- java.security.MessageDigest ---');

  final digestClass = JavaClass.forName(jvm, 'java.security.MessageDigest');
  final sha256 =
      digestClass.callStatic(
            'getInstance',
            '(Ljava/lang/String;)Ljava/security/MessageDigest;',
            ['SHA-256'],
          )
          as JavaObject;

  for (final input in ['hello', 'java_interop']) {
    // utf8.encode gives a Uint8List; Java bytes are signed, so values above
    // 127 arrive as their negative two's-complement counterpart — which is the
    // same eight bits, and what `& 0xff` below undoes.
    final digest =
        sha256.call('digest', '([B)[B', [utf8.encode(input)]) as JavaArray;
    final bytes = digest.toList() as Int8List;

    print(
      'sha256($input)'.padRight(24) +
          bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join(),
    );
    digest.release();
  }

  sha256.release();
  digestClass.release();
}

/// Currency and date formatting out of the JDK's locale database.
///
/// The thing Dart cannot do out of the box: `package:intl` needs locale data
/// shipped with your app, while a JDK already carries CLDR for every locale.
void _localeAwareFormatting(Jvm jvm) {
  print('\n--- java.text.NumberFormat + java.util.Locale ---');

  final localeClass = JavaClass.forName(jvm, 'java.util.Locale');
  final formatClass = JavaClass.forName(jvm, 'java.text.NumberFormat');

  for (final tag in ['pt-BR', 'en-US', 'de-DE', 'ja-JP']) {
    final locale =
        localeClass.callStatic(
              'forLanguageTag',
              '(Ljava/lang/String;)Ljava/util/Locale;',
              [tag],
            )
            as JavaObject;

    final currency =
        formatClass.callStatic(
              'getCurrencyInstance',
              '(Ljava/util/Locale;)Ljava/text/NumberFormat;',
              [locale],
            )
            as JavaObject;

    final formatted = currency.call('format', '(D)Ljava/lang/String;', [
      1234.5,
    ]);
    final language = locale.call('getDisplayName', '()Ljava/lang/String;');

    print('${tag.padRight(8)} $formatted   ($language)');

    currency.release();
    locale.release();
  }

  formatClass.release();
  localeClass.release();
}

/// A deflate/inflate round trip through `java.util.zip`.
///
/// Shows a Java array used as an *output buffer*: `deflate` writes into the
/// `byte[]` and returns how many bytes it wrote, so the array is shared with
/// Java rather than copied in and forgotten.
void _compression(Jvm jvm) {
  print('\n--- java.util.zip ---');

  final original = 'interop! ' * 64;
  final source = utf8.encode(original);

  final deflaterClass = JavaClass.forName(jvm, 'java.util.zip.Deflater');
  final deflater = deflaterClass.newInstance();

  // A buffer Java writes into, and Dart reads back out of.
  final buffer = JavaArray.sized(jvm, JniType.byte, 4096);

  deflater.call('setInput', '([B)V', [source]);
  deflater.call('finish', '()V');
  final compressedLength = deflater.call('deflate', '([B)I', [buffer]) as int;
  deflater.call('end', '()V');

  final compressed = buffer.toList(length: compressedLength) as Int8List;
  print(
    'deflate   ${source.length} bytes -> $compressedLength bytes '
    '(${(100 * compressedLength / source.length).toStringAsFixed(1)}%)',
  );

  final inflaterClass = JavaClass.forName(jvm, 'java.util.zip.Inflater');
  final inflater = inflaterClass.newInstance();

  inflater.call('setInput', '([B)V', [compressed]);
  final inflatedLength = inflater.call('inflate', '([B)I', [buffer]) as int;
  inflater.call('end', '()V');

  final inflated = buffer.toList(length: inflatedLength) as Int8List;
  final roundTripped = utf8.decode([for (final b in inflated) b & 0xff]);
  print(
    'inflate   $inflatedLength bytes, identical: '
    '${roundTripped == original}',
  );

  buffer.release();
  inflater.release();
  inflaterClass.release();
  deflater.release();
  deflaterClass.release();
}
