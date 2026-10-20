@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

const _fixtures = 'com.nfeflash.example.Fixtures';

/// Class loaders, classes defined from bytes, and the tool that embeds them.
void main() {
  /// The bytes of a class on the fixtures class path, read through the JDK.
  Uint8List classFileOf(String binaryName) {
    final stream = autoReleaseObject(
      testJvm.classFor('java.lang.ClassLoader').callJavaStaticAs<JavaObject>(
        'static java.io.InputStream getSystemResourceAsStream(String)',
        ['${binaryName.replaceAll('.', '/')}.class'],
      ),
    );
    return stream.callJavaAs<JavaArray>('byte[] readAllBytes()').toBytes();
  }

  JavaObject loader() {
    final loader = testJvm.newClassLoader();
    addTearDown(loader.release);
    return loader;
  }

  group('defineClass', () {
    test('defines a class that is distinct from the class path one', () {
      const name = _fixtures;
      final defined = testJvm.defineClass(loader(), name, classFileOf(name));
      addTearDown(defined.release);

      expect(defined.name, name);
      final onClassPath = testJvm.classFor(name);
      // Same name, same bytes, different loader: a different class.
      expect(defined.ref.isSameObject(onClassPath.ref), isFalse);
    });

    test('accepts the slashed form of the name', () {
      const name = _fixtures;
      final defined = testJvm.defineClass(
        loader(),
        'com/nfeflash/example/Fixtures',
        classFileOf(name),
      );
      addTearDown(defined.release);
      expect(defined.name, name);
    });

    test('defining the same name twice in one loader is a LinkageError', () {
      const name = _fixtures;
      final into = loader();
      final first = testJvm.defineClass(into, name, classFileOf(name));
      addTearDown(first.release);

      expect(
        () => testJvm.defineClass(into, name, classFileOf(name)),
        throwsA(
          isA<JavaException>().having(
            (e) => e.isA('java.lang.LinkageError'),
            'is a LinkageError',
            isTrue,
          ),
        ),
      );
    });

    test('bytes that are not a class file are a ClassFormatError', () {
      expect(
        () => testJvm.defineClass(
          loader(),
          'com.example.Nope',
          Uint8List.fromList([1, 2, 3, 4]),
        ),
        throwsA(
          isA<JavaException>().having(
            (e) => e.className,
            'className',
            'java.lang.ClassFormatError',
          ),
        ),
      );
    });

    test('defineClasses releases what it defined when one fails', () {
      const name = _fixtures;
      expect(
        () => testJvm.defineClasses(loader(), {
          name: classFileOf(name),
          'com.example.Broken': Uint8List.fromList([0]),
        }),
        throwsA(isA<JavaException>()),
      );
    });
  });

  test('a package-private superclass on the class path is out of reach', () {
    // Same package name, different loader: a different runtime package. The
    // class defined from bytes cannot see the class path's package-private
    // members — which is why an embedded helper uses public JDK types only.
    const name = 'com.nfeflash.example.Tasks';
    expect(
      () => testJvm.defineClass(loader(), name, classFileOf(name)),
      throwsA(
        isA<JavaException>().having(
          (e) => e.className,
          'className',
          'java.lang.IllegalAccessError',
        ),
      ),
    );
  });

  group('newClassLoader', () {
    test('its parent is the system loader unless one is given', () {
      final plain = loader();
      final system = autoReleaseObject(
        testJvm
            .classFor('java.lang.ClassLoader')
            .callJavaStaticAs<JavaObject>(
              'static ClassLoader getSystemClassLoader()',
            ),
      );
      final parent = autoReleaseObject(
        plain.callJavaAs<JavaObject>('ClassLoader getParent()'),
      );
      expect(parent.ref.isSameObject(system.ref), isTrue);

      final child = testJvm.newClassLoader(parent: plain);
      addTearDown(child.release);
      final childParent = autoReleaseObject(
        child.callJavaAs<JavaObject>('ClassLoader getParent()'),
      );
      expect(childParent.ref.isSameObject(plain.ref), isTrue);
    });
  });

  group('embed_java', () {
    test(
      'compiles a source into a map of class files, outer classes first',
      () {
        final work = Directory.systemTemp.createTempSync('embed_java_test_');
        addTearDown(() => work.deleteSync(recursive: true));

        final source = File('${work.path}/demo/Outer.java')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
package demo;

public final class Outer {
    static final class Inner {}

    public static String hello() {
        return new Object() { public String toString() { return "hi"; } }.toString();
    }
}
''');
        final out = '${work.path}/out/demo_classes.g.dart';

        final result = Process.runSync('dart', [
          'run',
          'java_interop:embed_java',
          '--out',
          out,
          '--name',
          'demoClasses',
          source.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

        final generated = File(out).readAsStringSync();
        expect(
          generated,
          contains('final Map<String, Uint8List> demoClasses = {'),
        );
        final names = RegExp(
          r"^  r'([\w.$]+)':",
          multiLine: true,
        ).allMatches(generated).map((m) => m.group(1)).toList();
        expect(names, ['demo.Outer', r'demo.Outer$1', r'demo.Outer$Inner']);
        expect(generated, contains('class file version: 55'));
      },
      skip: findJdkTool('javac') == null ? 'no javac' : null,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('without --out it prints the usage and fails', () {
      final result = Process.runSync('dart', [
        'run',
        'java_interop:embed_java',
        'Some.java',
      ]);
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('usage:'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
