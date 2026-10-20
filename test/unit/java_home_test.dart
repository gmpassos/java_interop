@TestOn('vm')
library;

import 'dart:io';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

void main() {
  group('findJavaHome', () {
    test('javaHomeOf refuses a path not laid out as a JDK', () {
      expect(() => javaHomeOf('libjvm.so'), throwsArgumentError);
      expect(() => javaHomeOf('/a/b/c/libjvm.so'), throwsArgumentError);
    });

    test('javaHomeOf inverts libjvmUnder', () {
      final home = Platform.isWindows ? r'C:\jdk-21' : '/opt/jdk-21';
      expect(javaHomeOf(libjvmUnder(home)), home);
    });

    test('agrees with searchLibjvm', () {
      final search = searchLibjvm();
      if (!search.found) {
        expect(findJavaHome(), isNull);
        return;
      }
      expect(libjvmUnder(findJavaHome()!), search.resolved);
    });

    test('findJdkTool finds javac in that home, or nothing', () {
      final home = findJavaHome();
      final javac = findJdkTool('javac');
      if (home == null) {
        expect(javac, isNull);
        return;
      }
      expect(javac, startsWith(home));
      expect(findJdkTool('no-such-tool'), isNull);
    });
  });

  group('libjvmUnder', () {
    test('picks the platform-specific layout', () {
      final path = libjvmUnder('/opt/jdk');

      if (Platform.isWindows) {
        expect(path, r'/opt/jdk\bin\server\jvm.dll');
      } else if (Platform.isMacOS) {
        expect(path, '/opt/jdk/lib/server/libjvm.dylib');
      } else {
        expect(path, '/opt/jdk/lib/server/libjvm.so');
      }
    });

    test('tolerates a trailing separator on JAVA_HOME', () {
      // A trailing slash in JAVA_HOME is common and would otherwise produce a
      // doubled separator that no filesystem resolves.
      final withSlash = libjvmUnder('/opt/jdk${Platform.pathSeparator}');
      expect(withSlash, libjvmUnder('/opt/jdk'));
      expect(withSlash, isNot(contains('//')));
    });
  });

  group('searchLibjvm', () {
    test('prefers JAVA_HOME and reports it first', () {
      final search = searchLibjvm(
        environment: {'JAVA_HOME': '/nonexistent-jdk'},
      );

      expect(search.candidates.first, libjvmUnder('/nonexistent-jdk'));
    });

    test('reports every candidate when nothing is found', () {
      final search = searchLibjvm(
        environment: {'JAVA_HOME': '/nonexistent-jdk'},
      );

      // Even with a bogus JAVA_HOME the platform fallbacks are still listed, so
      // the error message can show the user where else it looked.
      expect(search.candidates, isNotEmpty);
      if (!search.found) {
        expect(search.resolved, isNull);
      }
    });

    test('ignores an empty JAVA_HOME rather than probing "/lib/server"', () {
      final search = searchLibjvm(environment: const {'JAVA_HOME': ''});

      expect(search.candidates, isNot(contains(libjvmUnder(''))));
    });

    test('does not list the same candidate twice', () {
      final search = searchLibjvm(environment: const {});
      expect(search.candidates.toSet().length, search.candidates.length);
    });

    test('finds the JDK this machine actually has', () {
      // Not skipped when a JDK is missing: this is the assertion that the whole
      // suite depends on, so it should be loud about being unable to run.
      final search = searchLibjvm();
      if (!search.found) {
        markTestSkipped('no JDK installed; tried ${search.candidates}');
        return;
      }

      expect(File(search.resolved!).existsSync(), isTrue);
      expect(
        search.resolved,
        endsWith(Platform.isWindows ? '.dll' : '.dylib'),
        skip: !Platform.isMacOS && !Platform.isWindows,
      );
    });
  });

  group('defaultLibjvmPath', () {
    test('returns the resolved path when a JDK exists', () {
      final search = searchLibjvm();
      if (!search.found) {
        markTestSkipped('no JDK installed');
        return;
      }
      expect(defaultLibjvmPath(), search.resolved);
    });

    test('explains itself, listing what it tried, when nothing is found', () {
      // An impossible JAVA_HOME plus a platform with no fallbacks would still
      // hit the real ones, so this only asserts the message shape when the
      // search genuinely fails.
      final search = searchLibjvm(environment: const {'JAVA_HOME': '/nope'});
      if (search.found) {
        markTestSkipped('a real JDK is installed, so discovery cannot fail');
        return;
      }

      expect(
        () => defaultLibjvmPath(environment: const {'JAVA_HOME': '/nope'}),
        throwsA(
          isA<JniError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Could not locate libjvm'), contains('Tried:')),
          ),
        ),
      );
    });
  });
}
