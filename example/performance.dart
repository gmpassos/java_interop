/// Calling Java in a loop without paying for it twice.
///
/// Two costs dominate a hot interop loop, and both are avoidable:
///
/// 1. **Resolving members.** `GetMethodID` is a lookup in the VM plus two UTF-8
///    conversions. A [JavaClass] caches every id it resolves, for as long as it
///    holds the class reference — so hold the class.
/// 2. **Local references.** JNI hands back a local reference per call and, with
///    no native frame to return to, they accumulate until the reference table
///    overflows. Release them, or scope a whole loop in one
///    [JvmLocalFrames.localFrame].
///
/// The timings below are indicative, not a benchmark: they measure one machine,
/// once, with no warm-up.
///
/// Needs no jar and no class path.
///
/// ```sh
/// dart run example/performance.dart
/// ```
library;

import 'package:java_interop/java_interop.dart';

const _iterations = 200000;

void main() {
  final Jvm jvm;
  try {
    jvm = Jvm.startOrAttach();
  } on JniError catch (e) {
    print('No JVM available:\n$e');
    return;
  }

  _holdTheClass(jvm);
  _scopeTheReferences(jvm);
}

/// Holding a [JavaClass] versus looking it up on every call.
void _holdTheClass(Jvm jvm) {
  print('--- resolving members: $_iterations calls to Math.abs(int) ---');

  // Held: the class reference stays alive, so its member-id cache does too.
  final math = JavaClass.forName(jvm, 'java.lang.Math');
  final held = _time(() {
    for (var i = 0; i < _iterations; i++) {
      math.callStatic('abs', '(I)I', [-i]);
    }
  });
  print(
    'held class      ${held.inMilliseconds} ms   '
    '(${math.cachedMemberCount} member id cached)',
  );

  // Looked up each time: a FindClass, a GetStaticMethodID and a DeleteLocalRef
  // per call, and a fresh empty cache every time.
  final perCall = _time(() {
    for (var i = 0; i < _iterations; i++) {
      final clazz = JavaClass.forName(jvm, 'java.lang.Math');
      clazz.callStatic('abs', '(I)I', [-i]);
      clazz.release();
    }
  });
  print(
    'class per call  ${perCall.inMilliseconds} ms   '
    '(${_ratio(perCall, held)}x slower)',
  );

  math.release();
}

/// Releasing each local reference versus scoping the whole loop in one frame.
void _scopeTheReferences(Jvm jvm) {
  print('\n--- local references: $_iterations Java strings ---');

  // One release per iteration: correct, and the right default when the loop
  // body hands something back.
  final released = _time(() {
    for (var i = 0; i < _iterations; i++) {
      jvm.newString('value $i').release();
    }
  });
  print('release each    ${released.inMilliseconds} ms');

  // One frame around the loop: every local reference created inside is
  // reclaimed on the way out, with no per-iteration bookkeeping. Anything the
  // body needs to keep must be promoted with `toGlobal()` first.
  final framed = _time(() {
    jvm.localFrame(() {
      for (var i = 0; i < _iterations; i++) {
        jvm.newString('value $i');
      }
    }, capacity: 64);
  });
  print('one local frame ${framed.inMilliseconds} ms');

  print(
    '\nThese two land in the same range — a frame is about bookkeeping, not\n'
    'speed. It wins where releasing by hand is awkward: an early return, a\n'
    'throw, or a loop body that creates references it never names. What it\n'
    'does not do is help you keep one; promote that with toGlobal() first.\n'
    '\nDropping a local reference without either is the case to avoid: it\n'
    'overflows the reference table, which surfaces as a VM abort rather than\n'
    'a Dart exception.',
  );
}

Duration _time(void Function() body) {
  final stopwatch = Stopwatch()..start();
  body();
  return (stopwatch..stop()).elapsed;
}

String _ratio(Duration slower, Duration faster) =>
    (slower.inMicroseconds / faster.inMicroseconds).toStringAsFixed(1);
