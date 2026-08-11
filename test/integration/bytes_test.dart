@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// `byte[]` in both directions.
///
/// Java's `byte` is signed and Dart's binary APIs are unsigned, which makes this
/// the one conversion that produces plausible wrong answers rather than errors:
/// 200 arriving as -56 is still a number, and a file written from it is still a
/// file.
void main() {
  group('byte arrays', () {
    test('toBytes gives unsigned values across the whole range', () {
      final fixtures = fixturesClass();

      final array = autoReleaseObject(
        fixtures.callJavaStaticAs<JavaArray>('byte[] allByteValues()'),
      );

      final bytes = array.toBytes();

      expect(bytes, isA<Uint8List>());
      expect(bytes, hasLength(256));
      expect(bytes.first, 0);
      expect(bytes[127], 127);
      expect(bytes[128], 128, reason: 'signed would read this as -128');
      expect(bytes.last, 255, reason: 'signed would read this as -1');
      expect(bytes, [for (var i = 0; i < 256; i++) i]);
    });

    test('toList still gives the signed view', () {
      final fixtures = fixturesClass();

      final array = autoReleaseObject(
        fixtures.callJavaStaticAs<JavaArray>('byte[] allByteValues()'),
      );

      final signed = array.toList();
      expect(signed, isA<Int8List>());
      expect(signed[128], -128);
      expect(signed.last, -1);
    });

    test('an empty byte[] round-trips', () {
      final fixtures = fixturesClass();

      final array = autoReleaseObject(
        fixtures.callJavaStaticAs<JavaArray>('byte[] noBytes()'),
      );

      expect(array.toBytes(), isEmpty);
      expect(array.toBytes(), isA<Uint8List>());
    });

    test('start and length select a window', () {
      final fixtures = fixturesClass();

      final array = autoReleaseObject(
        fixtures.callJavaStaticAs<JavaArray>('byte[] allByteValues()'),
      );

      expect(array.toBytes(start: 250), [250, 251, 252, 253, 254, 255]);
      expect(array.toBytes(start: 10, length: 3), [10, 11, 12]);
    });

    /// The inbound direction: a `Uint8List` passed as `byte[]` has to arrive
    /// with the same eight bits per element, not truncated or sign-mangled.
    test('a Uint8List sent as byte[] arrives unchanged', () {
      final fixtures = fixturesClass();

      final values = Uint8List.fromList([for (var i = 0; i < 256; i++) i]);
      final expectedSum = values.fold<int>(0, (a, b) => a + b);

      expect(
        fixtures.callJavaStatic('int sumUnsignedBytes(byte[])', [values]),
        expectedSum,
      );
    });

    test('a full round trip preserves every value', () {
      final fixtures = fixturesClass();

      final array = autoReleaseObject(
        fixtures.callJavaStaticAs<JavaArray>('byte[] allByteValues()'),
      );
      final out = array.toBytes();

      expect(
        fixtures.callJavaStatic('int sumUnsignedBytes(byte[])', [out]),
        out.fold<int>(0, (a, b) => a + b),
      );
    });

    test('toBytes refuses a non-byte array', () {
      final fixtures = fixturesClass();

      final ints = autoReleaseObject(
        fixtures.callJavaStaticAs<JavaArray>('int[] intArray()'),
      );

      expect(
        () => ints.toBytes(),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            allOf(contains('byte[]'), contains('toList')),
          ),
        ),
      );
    });
  }, skip: skipWithoutJdk);
}
