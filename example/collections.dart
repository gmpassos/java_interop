/// Driving `java.util` collections with plain Dart values.
///
/// Generics erase to `Object`, so every collection method has a descriptor like
/// `(Ljava/lang/Object;)Z` — which is exactly the case boxing exists for. The
/// two converters at the bottom are the useful part: copy them.
///
/// Needs no jar and no class path.
///
/// ```sh
/// dart run example/collections.dart
/// ```
library;

import 'package:java_interop/java_interop.dart';

void main() {
  final Jvm jvm;
  try {
    jvm = Jvm.startOrAttach();
  } on JniError catch (e) {
    print('No JVM available:\n$e');
    return;
  }

  _lists(jvm);
  _maps(jvm);
}

void _lists(Jvm jvm) {
  print('--- java.util.ArrayList ---');

  final listClass = JavaClass.forName(jvm, 'java.util.ArrayList');
  final list = listClass.newInstance();

  // Dart ints, boxed into Integers because the parameter erased to Object.
  for (final value in [42, 7, 2026, -1]) {
    list.call('add', '(Ljava/lang/Object;)Z', [value]);
  }
  list.call('add', '(Ljava/lang/Object;)Z', ['a string, in the same list']);

  print('size            = ${list.call('size', '()I')}');
  print('toString        = ${list.javaToString()}');

  // Sorting happens in Java, on the Java objects.
  final collections = JavaClass.forName(jvm, 'java.util.Collections');
  final numbers = listClass.newInstance();
  for (final value in [42, 7, 2026, -1]) {
    numbers.call('add', '(Ljava/lang/Object;)Z', [value]);
  }
  collections.callStatic('sort', '(Ljava/util/List;)V', [numbers]);
  print('sorted          = ${dartListFrom(numbers)}');

  // …and the result comes back as ordinary Dart values.
  final back = dartListFrom(list);
  print('as Dart         = $back');
  print('runtime types   = ${back.map((e) => e.runtimeType).toList()}');

  numbers.release();
  collections.release();
  list.release();
  listClass.release();
}

void _maps(Jvm jvm) {
  print('\n--- java.util.HashMap ---');

  final mapClass = JavaClass.forName(jvm, 'java.util.HashMap');
  final map = mapClass.newInstance();

  const put = '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;';
  const get = '(Ljava/lang/Object;)Ljava/lang/Object;';

  // Keys and values are boxed on the way in. `put` returns the *previous*
  // value, declared Object — so even a Java null arrives as a JavaObject that
  // owns a reference, and dropping it on the floor would leak one per call.
  for (final entry in {
    'answer': 42,
    'pi': 3.14159,
    'enabled': true,
    'name': 'java_interop',
  }.entries) {
    final previous = map.call('put', put, [entry.key, entry.value]);
    if (previous is JavaObject) previous.release();
  }

  print('size            = ${map.call('size', '()I')}');

  // A single lookup: declared Object, so ask the value what it really is.
  final answer = map.call('get', get, ['answer']) as JavaObject;
  print('get("answer")   = ${answer.toDart()} (${answer.type.name})');
  answer.release();

  print('as Dart         = ${dartMapFrom(map)}');

  map.release();
  mapClass.release();
}

// ---------------------------------------------------------------------------
// Reusable converters
// ---------------------------------------------------------------------------

/// Copies any `java.util.List` into a Dart list, unboxing as it goes.
///
/// Every element is released as soon as it has been converted, so this holds at
/// most one Java reference at a time regardless of the list's size.
List<Object?> dartListFrom(JavaObject javaList) {
  final size = javaList.call('size', '()I') as int;

  return [
    for (var i = 0; i < size; i++)
      _take(javaList.call('get', '(I)Ljava/lang/Object;', [i])),
  ];
}

/// Copies any `java.util.Map` into a Dart map, unboxing keys and values.
///
/// Iterates the entry set rather than calling `get` per key, which is one pass
/// instead of two and works for maps whose keys are not `String`s.
Map<Object?, Object?> dartMapFrom(JavaObject javaMap) {
  final result = <Object?, Object?>{};

  final entrySet = javaMap.call('entrySet', '()Ljava/util/Set;') as JavaObject;
  final iterator =
      entrySet.call('iterator', '()Ljava/util/Iterator;') as JavaObject;

  while (iterator.call('hasNext', '()Z') as bool) {
    final entry = iterator.call('next', '()Ljava/lang/Object;') as JavaObject;
    // `entry`'s runtime class is an internal type (HashMap$Node), and its
    // `type` is resolved once and reused for both calls below. JNI resolves
    // and invokes without the access check core reflection would apply to a
    // non-public class, so the public interface methods are callable directly.
    final key = _take(entry.call('getKey', '()Ljava/lang/Object;'));
    final value = _take(entry.call('getValue', '()Ljava/lang/Object;'));
    result[key] = value;
    entry.release();
  }

  iterator.release();
  entrySet.release();
  return result;
}

/// Converts a call result to a plain Dart value and releases the reference.
///
/// `call` already converts a declared `String` or wrapper; what arrives here as
/// a [JavaObject] was declared `Object`, so only the VM knows what it holds.
Object? _take(Object? result) {
  if (result is! JavaObject) return result;
  try {
    final value = result.toDart();
    // toDart returns the object itself when it is not convertible; do not hand
    // back a reference that is about to be released.
    return identical(value, result) ? result.javaToString() : value;
  } finally {
    result.release();
  }
}
