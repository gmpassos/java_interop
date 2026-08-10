@TestOn('vm')
library;

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// U+0000, written as an escape: a literal NUL in a source file makes the file
/// binary to most tooling.
final nul = String.fromCharCode(0);

void main() {
  late Jvm jvm;
  late JavaClass fixtures;

  setUpAll(() => jvm = testJvm);
  setUp(() => fixtures = fixturesClass());

  /// Sends [value] to Java and reads it back, exercising both directions of
  /// the conversion.
  String? roundTrip(String? value) =>
      fixtures.callStatic(
            'echoString',
            '(Ljava/lang/String;)Ljava/lang/String;',
            [value],
          )
          as String?;

  group('round trips', () {
    test('ASCII', () {
      expect(roundTrip('hello'), 'hello');
    });

    test('empty string stays empty, and does not become null', () {
      // NewString with a zero length must still produce "" rather than a Java
      // null, which is why a non-null buffer is passed even when empty.
      expect(roundTrip(''), '');
      expect(roundTrip(''), isNotNull);
    });

    test('null stays null', () {
      expect(roundTrip(null), isNull);
    });

    test('Latin-1 accents', () {
      expect(roundTrip('três coração ÇÃO'), 'três coração ÇÃO');
    });

    test('CJK', () {
      expect(roundTrip('中文字符'), '中文字符');
    });

    test('astral characters (outside the BMP)', () {
      // The reason this binding uses NewString/GetStringChars rather than the
      // "UTF-8" family: JNI's modified UTF-8 encodes an astral character as two
      // 3-byte surrogates, which does not survive a naive round trip.
      expect(roundTrip('🎉'), '🎉');
      expect(roundTrip('a🎉b'), 'a🎉b');
      expect(roundTrip('👨‍👩‍👧‍👦'), '👨‍👩‍👧‍👦');
    });

    test('an embedded NUL survives', () {
      // Modified UTF-8 encodes U+0000 as 0xC0 0x80 precisely because a bare NUL
      // would terminate a C string; the UTF-16 path sidesteps the issue.
      final withNul = 'a${nul}b';
      expect(withNul.length, 3, reason: 'the NUL is a real code unit');

      expect(roundTrip(withNul), withNul);
      expect(roundTrip(nul), nul);
    });

    test('newlines, tabs and quotes', () {
      expect(
        roundTrip('line1\nline2\tend "quoted"'),
        'line1\nline2\tend "quoted"',
      );
    });

    test('a long string', () {
      final long = 'x' * 100000;
      expect(roundTrip(long), long);
    });
  });

  group('length semantics', () {
    int javaLength(String value) =>
        fixtures.callStatic('stringLength', '(Ljava/lang/String;)I', [value])
            as int;

    test('Java String.length() counts UTF-16 code units, as Dart does', () {
      expect(javaLength('hello'), 'hello'.length);
      expect(javaLength('ç'), 'ç'.length);
      expect(javaLength('🎉'), '🎉'.length);
      expect(javaLength('🎉'), 2, reason: 'an astral char is a surrogate pair');
      expect(javaLength(''), 0);
    });

    test('a NUL counts as one code unit on both sides', () {
      expect(javaLength('a${nul}b'), 3);
    });

    test('code points are preserved, not just code units', () {
      final codePoint =
          fixtures.callStatic('codePointAt', '(Ljava/lang/String;I)I', [
                '🎉',
                0,
              ])
              as int;

      expect(codePoint, 0x1F389);
      expect(String.fromCharCode(codePoint), '🎉');
    });
  });

  group('raw string API', () {
    test('newString and stringFrom mirror each other', () {
      final javaString = autoRelease(jvm.newString('hello'));
      expect(jvm.stringFrom(javaString), 'hello');
    });

    test('stringLength reports UTF-16 code units', () {
      expect(jvm.stringLength(autoRelease(jvm.newString('hello'))), 5);
      expect(jvm.stringLength(autoRelease(jvm.newString('🎉'))), 2);
      expect(jvm.stringLength(autoRelease(jvm.newString(''))), 0);
    });

    test('stringFrom of a Java null is null', () {
      final nullString = fixturesInstance(
        fixtures,
      ).call('nullString', '()Ljava/lang/String;');
      expect(nullString, isNull);
    });

    test('a string created in Dart is a real java.lang.String', () {
      final javaString = autoRelease(jvm.newString('hello'));
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));

      expect(jvm.isInstanceOf(javaString, stringClass), isTrue);
    });

    test('Java string methods work on a Dart-created string', () {
      final javaString = autoRelease(jvm.newString('Hello'));
      final stringClass = autoRelease(jvm.findClass('java.lang.String'));
      final toUpperCase = jvm.methodId(
        stringClass,
        'toUpperCase',
        '()Ljava/lang/String;',
      );

      final upper = autoRelease(jvm.callObjectMethod(javaString, toUpperCase));
      expect(jvm.stringFrom(upper), 'HELLO');
    });
  });

  group('strings as arguments and returns', () {
    test('concatenation through Java', () {
      expect(
        fixtures.callStatic(
          'staticConcat',
          '(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
          ['héllo ', 'wörld'],
        ),
        'héllo wörld',
      );
    });

    test('a null argument reaches Java as null', () {
      expect(
        fixtures.callStatic(
          'staticConcat',
          '(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
          ['x', null],
        ),
        'xnull',
      );
    });
  });
}
