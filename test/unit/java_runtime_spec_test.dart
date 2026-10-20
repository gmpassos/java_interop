@TestOn('vm')
library;

import 'dart:io';

import 'package:java_interop/provisioning.dart';
import 'package:test/test.dart';

/// Where a [JavaRuntimeSpec] puts its cache — pure path logic, no JVM.
void main() {
  const spec = JavaRuntimeSpec(
    name: 'demo_pkg',
    runtimeId: 'v1-demo2.0',
    cacheDirEnv: 'DEMO_JAVA_CACHE',
  );
  final sep = Platform.pathSeparator;

  group('cacheBaseDir', () {
    test('an override wins, made absolute', () {
      final dir = spec.cacheBaseDir(
        override: 'build${sep}cache',
        environment: const {'DEMO_JAVA_CACHE': '/elsewhere'},
      );
      expect(dir.isAbsolute, isTrue);
      expect(dir.path, endsWith('build${sep}cache'));
    });

    test('a blank override is no override', () {
      final dir = spec.cacheBaseDir(
        override: '  ',
        environment: const {'DEMO_JAVA_CACHE': '/from-env'},
      );
      expect(dir.path, '/from-env');
    });

    test('then the cache environment variable', () {
      expect(
        spec
            .cacheBaseDir(environment: const {'DEMO_JAVA_CACHE': '/from-env'})
            .path,
        '/from-env',
      );
    });

    test('then the operating system cache, under the package name', () {
      final dir = spec.cacheBaseDir(
        environment: const {
          'HOME': '/home/u',
          'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
        },
      );
      if (Platform.isMacOS) {
        expect(dir.path, '/home/u/Library/Caches/demo_pkg');
      } else if (Platform.isWindows) {
        expect(dir.path, r'C:\Users\u\AppData\Local\demo_pkg');
      } else {
        expect(dir.path, '/home/u/.cache/demo_pkg');
      }
    });

    test('XDG_CACHE_HOME counts on Linux', () {
      expect(
        spec.defaultCacheBasePath(
          environment: const {'HOME': '/home/u', 'XDG_CACHE_HOME': '/xdg'},
        ),
        '/xdg/demo_pkg',
      );
    }, skip: Platform.isMacOS || Platform.isWindows ? 'Linux only' : null);

    test('without a cache variable, the environment is ignored', () {
      const plain = JavaRuntimeSpec(name: 'demo_pkg', runtimeId: 'v1');
      expect(
        plain
            .cacheBaseDir(
              environment: const {'DEMO_JAVA_CACHE': '/x', 'HOME': '/h'},
            )
            .path,
        isNot('/x'),
      );
    });
  });

  test('runtimeDir is the base plus the runtime id', () {
    expect(spec.runtimeDir(override: '/base').path, '/base${sep}v1-demo2.0');
  });

  group('devRuntimeDir', () {
    test('is under the project\'s .dart_tool', () {
      final project = Directory.systemTemp.createTempSync('spec_dev_');
      addTearDown(() => project.deleteSync(recursive: true));
      Directory('${project.path}$sep.dart_tool').createSync();

      expect(
        spec.devRuntimeDir(projectDir: project.path)!.path,
        '${project.path}$sep.dart_tool${sep}demo_pkg${sep}v1-demo2.0',
      );
    });

    test('is null without a .dart_tool', () {
      final project = Directory.systemTemp.createTempSync('spec_dev_');
      addTearDown(() => project.deleteSync(recursive: true));
      expect(spec.devRuntimeDir(projectDir: project.path), isNull);
    });
  });

  test('says what it is', () {
    expect(spec.toString(), 'JavaRuntimeSpec(demo_pkg, v1-demo2.0)');
  });

  test('JavaRuntimeNotProvisioned says what to run and where it looked', () {
    final error = JavaRuntimeNotProvisioned(
      'nothing here',
      command: 'dart run demo_pkg:setup_jars',
      searched: ['/a', '/b'],
    );
    expect(
      error.toString(),
      allOf(
        contains('nothing here'),
        contains('Run: dart run demo_pkg:setup_jars'),
        contains('  - /b'),
      ),
    );
  });
}
