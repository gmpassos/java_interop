@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:java_interop/java_interop.dart' show classPathSeparator;
import 'package:java_interop/java_interop.dart' as ji show findJdkTool;
import 'package:java_interop/provisioning.dart';
import 'package:test/test.dart';

import '../support/jvm_fixture.dart';

/// Reading jars, verifying them, finding a provisioned class path, and
/// provisioning one — against jars built here with the JDK's `jar` tool, and
/// a stand-in for Maven. Real Maven runs only with
/// `JAVA_INTEROP_TEST_MAVEN=1`, since it needs its repository or the network.
void main() {
  final jarTool = ji.findJdkTool('jar');
  final skip = jarTool == null ? 'no JDK jar tool' : null;
  final sep = Platform.pathSeparator;

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('provisioning_'));
  tearDown(() => work.deleteSync(recursive: true));

  /// A jar at [name] in [work] holding [files] (path → text), compressed
  /// unless [stored].
  String makeJar(
    String name,
    Map<String, String> files, {
    bool stored = false,
  }) {
    final staging = Directory('${work.path}$sep.staging-$name')..createSync();
    for (final MapEntry(key: path, value: text) in files.entries) {
      File('${staging.path}$sep$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }
    final jar = '${work.path}$sep$name';
    final result = Process.runSync(jarTool!, [
      '--create',
      if (stored) '--no-compress',
      '--file',
      jar,
      '-C',
      staging.path,
      '.',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return jar;
  }

  group('JarFile', () {
    test('lists the entries of a real jar', () {
      final jar = JarFile.open(fixturesJarPath);
      expect(jar.names, contains('com/nfeflash/example/Fixtures.class'));
      expect(jar.contains('META-INF/MANIFEST.MF'), isTrue);
      expect(jar.contains('nope.txt'), isFalse);
      expect(jar.readText('nope.txt'), isNull);
    }, skip: skipWithoutJdk);

    test('reads a compressed entry and a stored one', () {
      const text = 'name="default"\nÀçentuação ✓\n';
      final compressed = JarFile.open(
        makeJar('c.jar', {'META-INF/x.xml': text * 50}),
      );
      final stored = JarFile.open(
        makeJar('s.jar', {'META-INF/x.xml': text}, stored: true),
      );
      expect(compressed.readText('META-INF/x.xml'), text * 50);
      expect(stored.readText('META-INF/x.xml'), text);
      expect(stored.readBytes('META-INF/x.xml'), utf8.encode(text));
    }, skip: skip);

    group('refuses what it does not read, rather than misreading it', () {
      /// The jar's bytes, with [patch] applied to the first central
      /// directory entry (at the offset it receives) or the end record.
      String patched(void Function(ByteData data, int central, int end) patch) {
        final source = makeJar('p.jar', {'a.txt': 'text' * 20});
        final bytes = File(source).readAsBytesSync();
        final data = ByteData.sublistView(bytes);
        var end = bytes.length - 22;
        while (data.getUint32(end, Endian.little) != 0x06054b50) {
          end--;
        }
        var central = data.getUint32(end + 16, Endian.little);
        // The first entry may be a directory; patch the a.txt one.
        while (true) {
          final nameLength = data.getUint16(central + 28, Endian.little);
          final name = utf8.decode(
            bytes.sublist(central + 46, central + 46 + nameLength),
          );
          if (name == 'a.txt') break;
          central +=
              46 +
              nameLength +
              data.getUint16(central + 30, Endian.little) +
              data.getUint16(central + 32, Endian.little);
        }
        patch(data, central, end);
        return (File(
          '${work.path}${sep}patched.jar',
        )..writeAsBytesSync(bytes)).path;
      }

      test('zip64', () {
        final path = patched(
          (data, _, end) => data.setUint16(end + 10, 0xffff, Endian.little),
        );
        expect(() => JarFile.open(path), throwsFormatException);
      }, skip: skip);

      test('encryption', () {
        final path = patched(
          (data, central, _) => data.setUint16(central + 8, 1, Endian.little),
        );
        expect(() => JarFile.open(path), throwsFormatException);
      }, skip: skip);

      test('a compression method other than stored or deflated', () {
        final path = patched(
          (data, central, _) => data.setUint16(central + 10, 12, Endian.little),
        );
        // The directory reads; the entry does not.
        final jar = JarFile.open(path);
        expect(() => jar.readText('a.txt'), throwsFormatException);
      }, skip: skip);

      test('a name that runs past the end of the file', () {
        final path = patched(
          (data, central, _) =>
              data.setUint16(central + 28, 0xfff0, Endian.little),
        );
        expect(() => JarFile.open(path), throwsFormatException);
      }, skip: skip);

      test('a local header past the end of the file', () {
        final path = patched(
          (data, central, _) =>
              data.setUint32(central + 42, 0x7ffffff0, Endian.little),
        );
        expect(
          () => JarFile.open(path).readText('a.txt'),
          throwsFormatException,
        );
      }, skip: skip);

      test('an entry whose local header is not where it says', () {
        final path = patched(
          (data, central, _) => data.setUint32(central + 42, 1, Endian.little),
        );
        expect(
          () => JarFile.open(path).readText('a.txt'),
          throwsFormatException,
        );
      }, skip: skip);

      test('a central directory that is not where it says', () {
        final path = patched(
          (data, _, end) => data.setUint32(end + 16, 0, Endian.little),
        );
        expect(() => JarFile.open(path), throwsFormatException);
      }, skip: skip);
    });

    test('a file that is not a zip is a FormatException', () {
      final file = File('${work.path}${sep}bad.jar')
        ..writeAsStringSync('not a zip at all');
      expect(() => JarFile.open(file.path), throwsFormatException);
    });
  });

  group('verifyJars', () {
    const spec = JavaRuntimeSpec(
      name: 'demo',
      runtimeId: 'v1',
      requiredClasses: {
        'com.example.Api': 'api.jar',
        'com.example.Impl': 'impl.jar',
      },
      requiredResources: ['META-INF/services/com.example.Api'],
      requiredResourceContent: {'META-INF/registry.xml': 'name="default"'},
      forbiddenClasses: {'com.example.Conflict': 'conflict.jar'},
    );

    test('a complete set passes', () {
      final api = makeJar('api.jar', {
        'com/example/Api.class': '',
        'META-INF/services/com.example.Api': 'com.example.Impl',
        // The wrong one first: another jar has the right one.
        'META-INF/registry.xml': '<impl name="dom"/>',
      });
      final impl = makeJar('impl.jar', {
        'com/example/Impl.class': '',
        'META-INF/registry.xml': '<impl name="default"/>',
      });

      final result = verifyJars(spec, [api, impl]);
      expect(result.ok, isTrue, reason: result.describe());
      expect(result.jarCount, 2);
      expect(result.describe(), contains('everything in place'));
    }, skip: skip);

    test('reports every kind of problem, naming what to do', () {
      final jar = makeJar('partial.jar', {
        'com/example/Api.class': '',
        'com/example/Conflict.class': '',
        'META-INF/registry.xml': '<impl name="dom"/>',
      });
      final missingJar = '${work.path}${sep}gone.jar';
      final notAZip = (File(
        '${work.path}${sep}broken.jar',
      )..writeAsStringSync('truncated download')).path;

      final result = verifyJars(spec, [jar, missingJar, notAZip]);
      expect(result.ok, isFalse);
      expect(result.missingClasses, {'com.example.Impl': 'impl.jar'});
      expect(result.missingResources, ['META-INF/services/com.example.Api']);
      expect(result.wrongResourceContent, {
        'META-INF/registry.xml': 'name="default"',
      });
      expect(result.forbiddenFound, {'com.example.Conflict': 'conflict.jar'});
      expect(result.unreadable.keys, [missingJar, notAZip]);
      expect(
        result.toString(),
        allOf(
          contains('missing class: com.example.Impl — expected from impl.jar'),
          contains('remove conflict.jar'),
          contains('no copy contains "name="default""'),
          contains('unreadable'),
        ),
      );
    }, skip: skip);

    test('a resource required by content but absent is missing', () {
      final jar = makeJar('empty.jar', {'x.txt': ''});
      const contentOnly = JavaRuntimeSpec(
        name: 'demo',
        runtimeId: 'v1',
        requiredResourceContent: {'META-INF/registry.xml': 'x'},
      );
      final result = verifyJars(contentOnly, [jar]);
      expect(result.missingResources, ['META-INF/registry.xml']);
      expect(result.wrongResourceContent, isEmpty);
    }, skip: skip);

    test('a truncated jar is reported unreadable, not a crash', () {
      final good = makeJar('whole.jar', {'com/example/Api.class': 'x' * 500});
      final bytes = File(good).readAsBytesSync();
      // Cut in the middle: the central directory is gone too.
      final cut = File('${work.path}${sep}cut.jar')
        ..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      final result = verifyJars(spec, [cut.path]);
      expect(result.unreadable.keys, [cut.path]);
      expect(result.jarCount, 0);
    }, skip: skip);

    test('a class directory with a trailing separator reads the same', () {
      final classes = Directory('${work.path}${sep}classes');
      File('${classes.path}${sep}com${sep}example${sep}Api.class')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      const apiOnly = JavaRuntimeSpec(
        name: 'demo',
        runtimeId: 'v1',
        requiredClasses: {'com.example.Api': 'api'},
      );
      expect(verifyJars(apiOnly, ['${classes.path}$sep']).ok, isTrue);
      expect(verifyJars(apiOnly, [classes.path]).ok, isTrue);
    });

    test('a class directory counts like a jar', () {
      final classes = Directory('${work.path}${sep}classes');
      File('${classes.path}${sep}com${sep}example${sep}Api.class')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File('${classes.path}${sep}com${sep}example${sep}Impl.class')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File('${classes.path}${sep}META-INF${sep}services${sep}com.example.Api')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File('${classes.path}${sep}META-INF${sep}registry.xml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name="default"');

      final result = verifyJars(spec, [classes.path]);
      expect(result.ok, isTrue, reason: result.describe());
      expect(result.jarCount, 0);
    });
  });

  group('resolveClassPath', () {
    const spec = JavaRuntimeSpec(
      name: 'demo_pkg',
      runtimeId: 'v2',
      cacheDirEnv: 'DEMO_CACHE',
      classPathEnv: 'DEMO_CLASSPATH',
      setupCommand: 'dart run demo_pkg:setup_jars',
    );

    /// A provisioned runtime under [base]: `jars/a.jar` and `classpath.txt`
    /// with a relative path, and a manifest for [runtimeId].
    Directory provisionAt(String base, {String runtimeId = 'v2'}) {
      final dir = Directory('$base$sep$runtimeId')..createSync(recursive: true);
      File('${dir.path}${sep}jars${sep}a.jar')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File(
        '${dir.path}$sep${JavaRuntimeSpec.classPathFileName}',
      ).writeAsStringSync('# a comment\n\njars/a.jar\n');
      File(
        '${dir.path}$sep${JavaRuntimeSpec.manifestFileName}',
      ).writeAsStringSync(jsonEncode({'runtimeId': runtimeId}));
      return dir;
    }

    test('an explicit class path wins', () {
      final jar = File('${work.path}${sep}x.jar')..writeAsStringSync('');
      final resolved = resolveClassPath(
        spec,
        explicit: [jar.path],
        environment: const {},
      );
      expect(resolved.source, ClassPathSource.explicit);
      expect(resolved.entries, [jar.path]);
      expect(resolved.runtimeDir, isNull);
    });

    test('an explicit class path with a missing entry fails, naming it', () {
      expect(
        () => resolveClassPath(
          spec,
          explicit: ['/nope/missing.jar'],
          environment: const {},
        ),
        throwsA(
          isA<JavaRuntimeNotProvisioned>().having(
            (e) => e.reason,
            'reason',
            contains('/nope/missing.jar'),
          ),
        ),
      );
    });

    test('the class path variable, as a separated list', () {
      final a = File('${work.path}${sep}a.jar')..writeAsStringSync('');
      final b = File('${work.path}${sep}b.jar')..writeAsStringSync('');
      final resolved = resolveClassPath(
        spec,
        environment: {
          'DEMO_CLASSPATH': '${a.path}$classPathSeparator${b.path}',
        },
      );
      expect(resolved.source, ClassPathSource.environment);
      expect(resolved.entries, [a.path, b.path]);
      expect(resolved.joined, '${a.path}$classPathSeparator${b.path}');
    });

    test('the class path variable, as a file of entries', () {
      final a = File('${work.path}${sep}a.jar')..writeAsStringSync('');
      final list = File('${work.path}${sep}classpath.list')
        ..writeAsStringSync('# jars\n${a.path}\n');
      final resolved = resolveClassPath(
        spec,
        environment: {'DEMO_CLASSPATH': list.path},
      );
      expect(resolved.entries, [a.path]);
    });

    test('a provisioned cache, with paths relative to it', () {
      final base = '${work.path}${sep}cache';
      final dir = provisionAt(base);
      final resolved = resolveClassPath(
        spec,
        environment: {'DEMO_CACHE': base},
        projectDir: work.path,
      );
      expect(resolved.source, ClassPathSource.cache);
      expect(resolved.runtimeDir!.path, dir.path);
      expect(resolved.entries.single, endsWith('v2${sep}jars/a.jar'));
      expect(File(resolved.entries.single).existsSync(), isTrue);
    });

    test('the cache can be moved: the paths are relative', () {
      final dir = provisionAt('${work.path}${sep}before');
      final moved = dir.parent.renameSync('${work.path}${sep}after');
      final resolved = resolveClassPath(
        spec,
        cacheDirOverride: moved.path,
        environment: const {},
      );
      expect(resolved.entries.single, startsWith(moved.path));
    });

    test('a cache of another runtime id is skipped', () {
      final base = '${work.path}${sep}cache';
      final dir = provisionAt(base);
      File(
        '${dir.path}$sep${JavaRuntimeSpec.manifestFileName}',
      ).writeAsStringSync(jsonEncode({'runtimeId': 'v1-older'}));
      expect(
        () => resolveClassPath(
          spec,
          environment: {'DEMO_CACHE': base},
          projectDir: work.path,
        ),
        throwsA(isA<JavaRuntimeNotProvisioned>()),
      );
    });

    test('a half-provisioned cache is skipped', () {
      final base = '${work.path}${sep}cache';
      final dir = provisionAt(base);
      File('${dir.path}${sep}jars${sep}a.jar').deleteSync();
      expect(
        () => resolveClassPath(
          spec,
          environment: {'DEMO_CACHE': base},
          projectDir: work.path,
        ),
        throwsA(isA<JavaRuntimeNotProvisioned>()),
      );
    });

    test('a manifest that is not JSON is skipped', () {
      final base = '${work.path}${sep}cache';
      final dir = provisionAt(base);
      File(
        '${dir.path}$sep${JavaRuntimeSpec.manifestFileName}',
      ).writeAsStringSync('{ broken');
      expect(
        () => resolveClassPath(
          spec,
          environment: {'DEMO_CACHE': base},
          projectDir: work.path,
        ),
        throwsA(isA<JavaRuntimeNotProvisioned>()),
      );
    });

    test('the project\'s .dart_tool, for development', () {
      provisionAt('${work.path}$sep.dart_tool${sep}demo_pkg');
      final resolved = resolveClassPath(
        spec,
        environment: {'HOME': '${work.path}${sep}home'},
        projectDir: work.path,
      );
      expect(resolved.source, ClassPathSource.dev);
      expect(resolved.runtimeFile(JavaRuntimeSpec.manifestFileName), isNotNull);
      expect(resolved.runtimeFile('nothing.txt'), isNull);
    });

    test('the process environment is the default', () {
      // Variables no environment has, so the process's own is read and
      // gives nothing; the override is the only place with a runtime.
      const unique = JavaRuntimeSpec(
        name: 'demo_pkg',
        runtimeId: 'v2',
        cacheDirEnv: 'JAVA_INTEROP_TEST_UNSET_CACHE',
        classPathEnv: 'JAVA_INTEROP_TEST_UNSET_CLASSPATH',
      );
      final base = '${work.path}${sep}cache';
      provisionAt(base);
      final resolved = resolveClassPath(unique, cacheDirOverride: base);
      expect(resolved.toString(), 'ResolvedClassPath(1 entries, from cache)');
      expect(unique.cacheBaseDir().isAbsolute, isTrue);
      expect(unique.runtimeDir().path, endsWith('v2'));
    });

    test('every entry comes back absolute', () {
      final previous = Directory.current;
      addTearDown(() => Directory.current = previous);
      Directory.current = work;
      File('${work.path}${sep}x.jar').writeAsStringSync('');
      Directory('${work.path}${sep}lists').createSync();
      File('${work.path}${sep}lists${sep}y.jar').writeAsStringSync('');
      final list = File('${work.path}${sep}lists${sep}cp.list')
        ..writeAsStringSync('y.jar\n');

      final explicit = resolveClassPath(
        spec,
        explicit: ['x.jar'],
        environment: const {},
      );
      expect(explicit.entries.single, '${Directory.current.path}${sep}x.jar');

      // A list file's relative lines are relative to the file, not to the
      // current directory.
      final fromList = resolveClassPath(
        spec,
        environment: {'DEMO_CLASSPATH': list.path},
      );
      expect(fromList.entries.single, endsWith('lists${sep}y.jar'));
      expect(File(fromList.entries.single).isAbsolute, isTrue);
    });

    test('a cache whose provisioning failed verification is skipped', () {
      final base = '${work.path}${sep}cache';
      final dir = provisionAt(base);
      File(
        '${dir.path}$sep${JavaRuntimeSpec.manifestFileName}',
      ).writeAsStringSync(jsonEncode({'runtimeId': 'v2', 'verified': false}));
      expect(
        () => resolveClassPath(
          spec,
          cacheDirOverride: base,
          environment: const {},
        ),
        throwsA(isA<JavaRuntimeNotProvisioned>()),
      );
    });

    test('an absolute entry in classpath.txt is kept as it is', () {
      final base = '${work.path}${sep}cache';
      final dir = provisionAt(base);
      final elsewhere = File('${work.path}${sep}elsewhere.jar')
        ..writeAsStringSync('');
      File(
        '${dir.path}$sep${JavaRuntimeSpec.classPathFileName}',
      ).writeAsStringSync('${elsewhere.path}\njars/a.jar\n');
      final resolved = resolveClassPath(
        spec,
        cacheDirOverride: base,
        environment: const {},
      );
      expect(resolved.entries.first, elsewhere.path);
      expect(readRuntimeClassPath(spec, dir), resolved.entries);
    });

    test('nothing anywhere: the command to run and every place searched', () {
      expect(
        () => resolveClassPath(
          spec,
          environment: {
            'HOME': '${work.path}${sep}home',
            'DEMO_CACHE': '${work.path}${sep}cache',
          },
          projectDir: work.path,
        ),
        throwsA(
          isA<JavaRuntimeNotProvisioned>()
              .having((e) => e.command, 'command', spec.setupCommand)
              .having((e) => e.searched, 'searched', hasLength(2)),
        ),
      );
    });
  });

  group('provisioning', () {
    /// This package itself is the one whose POM is read.
    JavaRuntimeSpec specFor(String runtimeId, {Map<String, String>? classes}) =>
        JavaRuntimeSpec(
          name: 'java_interop',
          runtimeId: runtimeId,
          pomPackageFile: 'test/provisioning/pom.xml',
          cacheDirEnv: 'JAVA_INTEROP_TEST_CACHE',
          requiredClasses: classes ?? const {},
          loggingProperties: '.level=WARNING\n',
          manifestExtras: const {'libraryVersion': '1'},
        );

    /// A stand-in for `mvn`: copies [jar] into the `-DoutputDirectory` it is
    /// given, as `copy-dependencies` would, and records its arguments — or
    /// fails with [exitCode].
    String fakeMaven(String jar, {int exitCode = 0}) {
      final script = File('${work.path}${sep}mvn')
        ..writeAsStringSync('''
#!/bin/sh
echo "\$@" > "${work.path}/mvn-args"
if [ $exitCode -ne 0 ]; then echo "resolution failed" >&2; exit $exitCode; fi
out=""
for arg in "\$@"; do
  case "\$arg" in -DoutputDirectory=*) out="\${arg#-DoutputDirectory=}";; esac
done
[ -n "\$out" ] || { echo "no -DoutputDirectory" >&2; exit 9; }
mkdir -p "\$out"
cp "$jar" "\$out/"
''');
      Process.runSync('chmod', ['+x', script.path]);
      return script.path;
    }

    test('resolves, writes the cache, and verifies', () async {
      final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
      final spec = specFor('v1', classes: {'com.example.Api': 'lib'});
      final lines = <String>[];

      final result = await provisionJavaRuntime(
        spec,
        cacheDir: '${work.path}${sep}cache',
        maven: fakeMaven(jar),
        offline: true,
        log: lines.add,
      );

      expect(result.ok, isTrue, reason: result.verification.describe());
      expect(result.provisioned, isTrue);
      expect(result.jarCount, 1);
      expect(result.totalBytes, File(jar).lengthSync());
      expect(lines.last, contains('1 jars'));

      final dir = result.runtimeDir;
      expect(
        File('${dir.path}${sep}pom.xml').readAsStringSync(),
        contains('provisioning-fixture'),
      );
      expect(
        File(
          '${dir.path}$sep${JavaRuntimeSpec.classPathFileName}',
        ).readAsLinesSync().where((l) => !l.startsWith('#')),
        ['jars/lib.jar'],
      );
      expect(
        File(
          '${dir.path}$sep${JavaRuntimeSpec.loggingPropertiesFileName}',
        ).readAsStringSync(),
        '.level=WARNING\n',
      );
      final manifest =
          jsonDecode(
                File(
                  '${dir.path}$sep${JavaRuntimeSpec.manifestFileName}',
                ).readAsStringSync(),
              )
              as Map;
      expect(manifest['runtimeId'], 'v1');
      expect(manifest['libraryVersion'], '1');
      expect(manifest['verified'], isTrue);
      expect((manifest['jars'] as List).single['name'], 'lib.jar');

      final args = File('${work.path}${sep}mvn-args').readAsStringSync();
      expect(args, contains('-o'));
      expect(args, contains('-DincludeScope=runtime'));
      expect(
        args,
        contains('-DoutputDirectory=${JavaRuntimeSpec.jarsDirName}'),
      );
      expect(args, contains('dependency:copy-dependencies'));

      // And the runtime it made is one resolveClassPath finds.
      final resolved = resolveClassPath(
        spec,
        cacheDirOverride: '${work.path}${sep}cache',
        environment: const {},
      );
      expect(resolved.entries.single, endsWith('lib.jar'));
    }, skip: skip ?? (Platform.isWindows ? 'sh script' : null));

    test(
      'an interrupted provisioning is not taken for a finished one',
      () async {
        final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
        final spec = specFor('v1', classes: {'com.example.Api': 'lib'});
        final cache = '${work.path}${sep}cache';
        // What a run killed half-way used to leave: jars/, nothing else; and a
        // staging directory from another killed run.
        final runtime = spec.runtimeDir(override: cache);
        Directory('${runtime.path}${sep}jars').createSync(recursive: true);
        Directory('${runtime.path}.partial').createSync(recursive: true);

        final result = await provisionJavaRuntime(
          spec,
          cacheDir: cache,
          maven: fakeMaven(jar),
        );
        expect(result.provisioned, isTrue);
        expect(result.ok, isTrue, reason: result.verification.describe());
        expect(Directory('${runtime.path}.partial').existsSync(), isFalse);
        expect(Directory('${runtime.path}.previous').existsSync(), isFalse);
      },
      skip: skip ?? (Platform.isWindows ? 'sh script' : null),
    );

    test('a failed --force leaves the previous runtime as it was', () async {
      final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
      final spec = specFor('v1');
      final cache = '${work.path}${sep}cache';
      final first = await provisionJavaRuntime(
        spec,
        cacheDir: cache,
        maven: fakeMaven(jar),
      );

      await expectLater(
        provisionJavaRuntime(
          spec,
          cacheDir: cache,
          maven: fakeMaven(jar, exitCode: 1),
          force: true,
        ),
        throwsA(isA<MavenFailed>()),
      );

      // Still there, still resolvable: a running deployment never noticed.
      final resolved = resolveClassPath(
        spec,
        cacheDirOverride: cache,
        environment: const {},
      );
      expect(resolved.runtimeDir!.path, first.runtimeDir.path);
      expect(
        Directory('${first.runtimeDir.path}.partial').existsSync(),
        isFalse,
      );
    }, skip: skip ?? (Platform.isWindows ? 'sh script' : null));

    test('a runtime failing verification is kept for inspection, but not '
        'resolved', () async {
      final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
      final spec = specFor('v1', classes: {'com.example.Missing': 'x.jar'});
      final cache = '${work.path}${sep}cache';
      final result = await provisionJavaRuntime(
        spec,
        cacheDir: cache,
        maven: fakeMaven(jar),
      );
      expect(result.ok, isFalse);
      expect(
        File(
          '${result.runtimeDir.path}$sep${JavaRuntimeSpec.manifestFileName}',
        ).readAsStringSync(),
        contains('"verified": false'),
      );
      expect(
        () => resolveClassPath(
          spec,
          cacheDirOverride: cache,
          environment: const {},
        ),
        throwsA(isA<JavaRuntimeNotProvisioned>()),
      );
    }, skip: skip ?? (Platform.isWindows ? 'sh script' : null));

    test('already provisioned: only verified, unless forced', () async {
      final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
      final spec = specFor('v1');
      final maven = fakeMaven(jar);
      final cache = '${work.path}${sep}cache';

      await provisionJavaRuntime(spec, cacheDir: cache, maven: maven);
      File('${work.path}${sep}mvn-args').deleteSync();

      final again = await provisionJavaRuntime(
        spec,
        cacheDir: cache,
        maven: maven,
      );
      expect(again.provisioned, isFalse);
      expect(again.ok, isTrue);
      expect(File('${work.path}${sep}mvn-args').existsSync(), isFalse);

      final forced = await provisionJavaRuntime(
        spec,
        cacheDir: cache,
        maven: maven,
        force: true,
      );
      expect(forced.provisioned, isTrue);
      expect(File('${work.path}${sep}mvn-args').existsSync(), isTrue);
    }, skip: skip ?? (Platform.isWindows ? 'sh script' : null));

    test('Maven failing is a MavenFailed with its output', () async {
      final maven = fakeMaven('/dev/null', exitCode: 1);
      await expectLater(
        provisionJavaRuntime(
          specFor('v1'),
          cacheDir: '${work.path}${sep}cache',
          maven: maven,
        ),
        throwsA(
          isA<MavenFailed>()
              .having((e) => e.exitCode, 'exitCode', 1)
              .having((e) => e.output, 'output', contains('resolution failed')),
        ),
      );
    }, skip: Platform.isWindows ? 'sh script' : null);

    test('Maven succeeding but copying nothing is a StateError', () async {
      final script = File('${work.path}${sep}mvn')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', script.path]);
      await expectLater(
        provisionJavaRuntime(
          specFor('v1'),
          cacheDir: '${work.path}${sep}cache',
          maven: script.path,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no jars'),
          ),
        ),
      );
    }, skip: Platform.isWindows ? 'sh script' : null);

    test('without one named, Maven is found where it is installed', () async {
      final found = await locateMaven(environment: const {});
      expect(File(found).existsSync(), isTrue);
    }, skip: _hasMaven ? null : 'no Maven installed');

    test('a Maven that is not there is not replaced by another', () async {
      await expectLater(
        locateMaven(explicit: '${work.path}${sep}no-mvn'),
        throwsA(isA<MavenNotFound>()),
      );
    });

    test('a POM the package does not have is a StateError', () async {
      const spec = JavaRuntimeSpec(
        name: 'java_interop',
        runtimeId: 'v1',
        pomPackageFile: 'tool/no-such-pom.xml',
      );
      await expectLater(readPackagePom(spec), throwsStateError);
    });

    group('runProvisioningCli', () {
      Future<(int, String, String)> cli(
        JavaRuntimeSpec spec,
        List<String> args,
      ) async {
        final out = _Capture();
        final err = _Capture();
        final code = await runProvisioningCli(
          spec,
          args,
          out: out.sink,
          err: err.sink,
          environment: const {},
        );
        return (code, out.text, err.text);
      }

      test('--help is 0, an unknown option 1', () async {
        final (help, helpOut, _) = await cli(specFor('v1'), ['--help']);
        expect(help, 0);
        expect(helpOut, contains('--print-classpath'));
        final (bad, _, badErr) = await cli(specFor('v1'), ['--nope']);
        expect(bad, 1);
        expect(badErr, contains('usage:'));
      });

      test('provisions (0), prints the class path, verifies', () async {
        final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
        final spec = specFor('v1', classes: {'com.example.Api': 'lib'});
        final cache = '${work.path}${sep}cache';

        final (code, out, _) = await cli(spec, [
          '--cache-dir',
          cache,
          '--maven',
          fakeMaven(jar),
        ]);
        expect(code, 0);
        expect(out, contains('everything in place'));
        expect(out, contains('JAVA_INTEROP_TEST_CACHE='));

        final (printed, classPath, _) = await cli(spec, [
          '--cache-dir',
          cache,
          '--print-classpath',
        ]);
        expect(printed, 0);
        expect(classPath.trim(), endsWith('lib.jar'));

        final (verified, _, _) = await cli(spec, [
          '--cache-dir',
          cache,
          '--verify-only',
        ]);
        expect(verified, 0);
      }, skip: skip ?? (Platform.isWindows ? 'sh script' : null));

      test('a set that fails verification is 4', () async {
        final jar = makeJar('lib.jar', {'com/example/Api.class': ''});
        final spec = specFor('v1', classes: {'com.example.Missing': 'x.jar'});
        final (code, _, err) = await cli(spec, [
          '--cache-dir',
          '${work.path}${sep}cache',
          '--maven',
          fakeMaven(jar),
        ]);
        expect(code, 4);
        expect(err, contains('com.example.Missing'));
      }, skip: skip ?? (Platform.isWindows ? 'sh script' : null));

      test('no Maven is 2, Maven failing 3, nothing provisioned 3', () async {
        final cache = ['--cache-dir', '${work.path}${sep}cache'];
        final (noMaven, _, noMavenErr) = await cli(specFor('v1'), [
          ...cache,
          '--maven',
          '${work.path}${sep}no-mvn',
        ]);
        expect(noMaven, 2);
        expect(noMavenErr, contains('JAVA_INTEROP_TEST_CACHE'));

        if (!Platform.isWindows) {
          // There, but not executable: still "no Maven", not a crash.
          final notExecutable = File('${work.path}${sep}mvn-noexec')
            ..writeAsStringSync('#!/bin/sh\n');
          final (cannotRun, _, cannotRunErr) = await cli(specFor('v1'), [
            ...cache,
            '--maven',
            notExecutable.path,
          ]);
          expect(cannotRun, 2);
          expect(cannotRunErr, contains('could not be run'));
        }

        if (!Platform.isWindows) {
          final (failed, _, _) = await cli(specFor('v1'), [
            ...cache,
            '--maven',
            fakeMaven('/dev/null', exitCode: 7),
          ]);
          expect(failed, 3);
        }

        final (nothing, _, nothingErr) = await cli(specFor('v9'), [
          ...cache,
          '--verify-only',
        ]);
        expect(nothing, 3);
        expect(nothingErr, contains('not provisioned'));
      });
    });

    test(
      'with real Maven',
      () async {
        final result = await provisionJavaRuntime(
          specFor('v-real', classes: {'javax.inject.Inject': 'javax.inject'}),
          cacheDir: '${work.path}${sep}cache',
          offline:
              Platform.environment['JAVA_INTEROP_TEST_MAVEN_OFFLINE'] == '1',
        );
        expect(result.ok, isTrue, reason: result.verification.describe());
        expect(result.jarCount, 1);
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: Platform.environment['JAVA_INTEROP_TEST_MAVEN'] == '1'
          ? null
          : 'needs Maven and its repository: JAVA_INTEROP_TEST_MAVEN=1',
    );
  });
}

final _hasMaven =
    Process.runSync(Platform.isWindows ? 'where' : 'which', ['mvn']).exitCode ==
    0;

/// An [IOSink] whose text a test can read.
class _Capture {
  final _buffer = BytesBuilder();
  late final IOSink sink = IOSink(_BufferConsumer(_buffer));
  String get text => utf8.decode(_buffer.toBytes());
}

class _BufferConsumer implements StreamConsumer<List<int>> {
  _BufferConsumer(this._buffer);
  final BytesBuilder _buffer;

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(_buffer.add);

  @override
  Future<void> close() async {}
}
