/// Configuring `java.util.logging` from Dart.
library;

import 'dart:convert';

import 'java_class.dart';
import 'java_ref.dart';
import 'jvm.dart';
import 'jvm_diagnostics.dart';

/// `java.util.logging`, configured from Dart.
///
/// Java libraries log through `java.util.logging` to stderr at `INFO` unless
/// told otherwise — and an embedded VM was told nothing, so a chatty library
/// writes a dozen lines per call into the Dart process's output.
///
/// The obvious fix, `Logger.getLogger(name).setLevel(level)`, does not work
/// through JNI: `getLogger` is caller-sensitive, and with no Java frame on the
/// stack it throws or returns a logger detached from the configuration. It
/// would not last either: the `LogManager` holds loggers weakly, so a logger
/// configured by hand can be collected, recreated with no level, and start
/// logging at `INFO` again weeks later. This configures the `LogManager`
/// itself instead, which applies to loggers created later too.
extension JvmJavaLogging on Jvm {
  /// Replaces the `java.util.logging` configuration: [rootLevel] for
  /// everything, and [levels] — logger name (a package, usually) to level
  /// name: `SEVERE`, `WARNING`, `INFO`, `FINE`, `OFF`, … — for the named
  /// loggers and their children.
  ///
  /// With [console] (the default), records go to stderr through a
  /// `ConsoleHandler` with the `SimpleFormatter`, as they do out of the box;
  /// `readConfiguration` replaces the *whole* configuration, so without it
  /// even the warnings would disappear. [properties] are added as they are,
  /// for anything else — a handler's own settings, a format.
  ///
  /// ```dart
  /// jvm.configureJavaLogging(levels: {
  ///   'org.apache.axis2': 'WARNING',
  ///   'org.apache.commons.httpclient': 'WARNING',
  /// });
  /// ```
  void configureJavaLogging({
    Map<String, String> levels = const {},
    String rootLevel = 'INFO',
    bool console = true,
    Map<String, String> properties = const {},
  }) {
    final text = [
      if (console) ...[
        'handlers=java.util.logging.ConsoleHandler',
        'java.util.logging.ConsoleHandler.level=ALL',
        'java.util.logging.ConsoleHandler.formatter='
            'java.util.logging.SimpleFormatter',
      ],
      '.level=$rootLevel',
      for (final MapEntry(:key, :value) in levels.entries) '$key.level=$value',
      for (final MapEntry(:key, :value) in properties.entries) '$key=$value',
    ].join('\n');

    localFrame(() {
      final stream = classFor(
        'java.io.ByteArrayInputStream',
      ).newJava('(byte[])', [utf8.encode(text)]);
      _logManager().callJava('void readConfiguration(java.io.InputStream)', [
        stream,
      ]);
    }, capacity: 16);
  }

  /// The level the `java.util.logging` configuration gives [loggerName]
  /// itself — `WARNING`, say — or `null` when it sets none and the logger
  /// inherits its parent's.
  ///
  /// Read from the `LogManager`'s properties, not from a `Logger`, for the
  /// reason [configureJavaLogging] explains.
  String? javaLogLevel(String loggerName) =>
      javaLoggingProperty('$loggerName.level');

  /// A property of the `java.util.logging` configuration, or `null`.
  String? javaLoggingProperty(String key) => localFrame(
    () =>
        _logManager().callJavaAs<String?>('String getProperty(String)', [key]),
    capacity: 8,
  );

  JavaObject _logManager() =>
      classFor('java.util.logging.LogManager').callJavaStaticAs<JavaObject>(
        'static java.util.logging.LogManager getLogManager()',
      );
}
