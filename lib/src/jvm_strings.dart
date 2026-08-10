/// Moving strings across the JNI boundary.
///
/// The UTF-16 (`jchar`) family is used rather than the UTF-8 one. JNI's
/// "UTF-8" is *modified* UTF-8: U+0000 is encoded as two bytes and characters
/// outside the BMP are encoded as a surrogate pair of three bytes each, so a
/// Dart string containing an emoji or a NUL does not survive a
/// `NewStringUTF`/`GetStringUTFChars` round trip. Dart strings are already
/// sequences of UTF-16 code units, so `NewString`/`GetStringChars` is both
/// exact and cheaper.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';

/// String conversion.
extension JvmStrings on Jvm {
  /// Copies a Dart string into a new `java.lang.String`.
  ///
  /// The returned reference is local; release it when done.
  JavaRef newString(String value) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(
      env,
      JniFn.newString,
    ).cast<NativeFunction<NewStringC>>().asFunction<NewStringDart>();

    final units = value.codeUnits;

    final string = using((arena) {
      // A zero-length string still needs a valid (non-null) pointer: passing
      // nullptr would create a Java null rather than "".
      final buffer = arena<Uint16>(units.isEmpty ? 1 : units.length);
      for (var i = 0; i < units.length; i++) {
        buffer[i] = units[i];
      }
      return fn(env, buffer, units.length);
    });

    checkException();
    return JavaRef(this, string, JavaRefKind.local);
  }

  /// Copies a `java.lang.String` back into Dart.
  ///
  /// Returns `null` when [string] holds a Java `null`, mirroring the Java side
  /// rather than collapsing null into `''`.
  String? stringFrom(JavaRef string) {
    if (string.isNull) return null;

    final env = this.env;
    final getLength = Jvm.fnSlotOf(env, JniFn.getStringLength)
        .cast<NativeFunction<GetStringLengthC>>()
        .asFunction<GetStringLengthDart>();
    final getChars = Jvm.fnSlotOf(
      env,
      JniFn.getStringChars,
    ).cast<NativeFunction<GetStringCharsC>>().asFunction<GetStringCharsDart>();
    final releaseChars = Jvm.fnSlotOf(env, JniFn.releaseStringChars)
        .cast<NativeFunction<ReleaseStringCharsC>>()
        .asFunction<ReleaseStringCharsDart>();

    final length = getLength(env, string.pointer);
    final chars = getChars(env, string.pointer, nullptr);
    if (chars == nullptr) {
      checkException();
      return null;
    }

    try {
      // `asTypedList` views VM-owned memory; copy out before releasing it.
      return String.fromCharCodes(chars.asTypedList(length));
    } finally {
      releaseChars(env, string.pointer, chars);
    }
  }

  /// The length of a `java.lang.String` in UTF-16 code units.
  ///
  /// Matches Java's `String.length()`, which counts code *units* — an emoji
  /// counts as 2, exactly as in Dart.
  int stringLength(JavaRef string) {
    final env = this.env;
    final fn = Jvm.fnSlotOf(env, JniFn.getStringLength)
        .cast<NativeFunction<GetStringLengthC>>()
        .asFunction<GetStringLengthDart>();
    return fn(env, string.pointer);
  }
}
