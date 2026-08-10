@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:java_interop/java_interop.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

void main() {
  group('Jvm lifecycle', () {
    test('startOrAttach returns the same VM every time', () {
      final first = testJvm;
      final second = Jvm.startOrAttach(classPath: [fixturesJarPath]);

      expect(identical(first, second), isTrue);
      expect(first.vm, second.vm);
      expect(Jvm.current, same(first));
      expect(Jvm.isRunning, isTrue);
    });

    test('reports a JNI version of at least 1.6', () {
      // Everything this binding uses exists in 1.6; a modern JDK reports much
      // higher, but the floor is what matters.
      expect(testJvm.version, greaterThanOrEqualTo(JniVersion.v1_6));
    });

    test('exposes the class path it was created with', () {
      final jvm = testJvm;
      // Only the isolate that actually created the VM knows the class path;
      // one that attached later gets an empty list by design.
      expect(jvm.classPath, anyOf(isEmpty, contains(fixturesJarPath)));
    });

    test('toString identifies the VM handle', () {
      expect(testJvm.toString(), startsWith('Jvm(0x'));
    });
  });

  group('thread affinity', () {
    // A Dart isolate is not pinned to an OS thread: it can resume on a
    // different one after an await. A cached JNIEnv* would be a latent crash,
    // so `env` re-resolves through GetEnv on every access.
    test('env is usable after an await', () async {
      final jvm = testJvm;
      final before = jvm.env;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = jvm.env;
      expect(after, isNot(nullptr));
      expect(before.address, isPositive);

      // Whether or not the isolate moved threads, calls must keep working.
      final clazz = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');
      addTearDown(clazz.release);
      expect(clazz.callStatic('staticSum', '(II)I', [1, 2]), 3);
    });

    test('calls keep working across many async gaps', () async {
      final clazz = fixturesClass();

      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(Duration.zero);
        expect(clazz.callStatic('staticSum', '(II)I', [i, i]), i * 2);
      }
    });

    test('another isolate attaches to the same VM', () async {
      // The scenario `dart test` itself creates: several isolates in one
      // process, only one of which may call JNI_CreateJavaVM.
      final jar = fixturesJarPath;
      final result = await Isolate.run(() {
        final jvm = Jvm.startOrAttach(classPath: [jar]);
        final clazz = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');
        try {
          return clazz.callStatic('staticSum', '(II)I', [20, 22]) as int;
        } finally {
          clazz.release();
        }
      });

      expect(result, 42);

      // The parent isolate's handle is still healthy afterwards.
      expect(fixturesClass().callStatic('staticSum', '(II)I', [1, 1]), 2);
    });

    test('two isolates can call concurrently', () async {
      final jar = fixturesJarPath;

      Future<int> work(int seed) => Isolate.run(() {
        final jvm = Jvm.startOrAttach(classPath: [jar]);
        final clazz = JavaClass.forName(jvm, 'com.nfeflash.example.Fixtures');
        try {
          var total = 0;
          for (var i = 0; i < 50; i++) {
            total =
                clazz.callStatic('staticSum', '(II)I', [total, seed]) as int;
          }
          return total;
        } finally {
          clazz.release();
        }
      });

      expect(await Future.wait([work(1), work(2), work(3)]), [50, 100, 150]);
    });
  });

  group('classPathSeparator', () {
    test('is the list separator, not the path separator', () {
      expect(classPathSeparator, Platform.isWindows ? ';' : ':');
      // The mix-up this guards against: Platform.pathSeparator is `\` on
      // Windows, which would join two jars into one bogus entry.
      if (Platform.isWindows) {
        expect(classPathSeparator, isNot(Platform.pathSeparator));
      }
    });
  });
}
