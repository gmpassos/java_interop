/// The VM options an embedded JVM usually wants, as a value.
library;

/// The `vmOptions` for [Jvm.startOrAttach], built from named settings.
///
/// A JVM started from inside a Dart process is not a `java` command line: no
/// launcher picks the encoding or the AWT mode for it, and the defaults that
/// suit a desktop application suit a server badly. This collects the ones
/// that matter, with defaults for an embedded VM:
///
/// ```dart
/// final jvm = Jvm.startOrAttach(
///   classPath: jars,
///   vmOptions: const JvmOptions(maxHeapMb: 512, timeZone: 'UTC').build(),
/// );
/// ```
///
/// A pure value: [build] needs no JVM, so a test can check the options an
/// application would start with.
class JvmOptions {
  const JvmOptions({
    this.headless = true,
    this.encoding = 'UTF-8',
    this.timeZone,
    this.maxHeapMb,
    this.initialHeapMb,
    this.usePerfData = true,
    this.loggingConfigFile,
    this.systemProperties = const {},
    this.extra = const [],
  });

  /// `-Djava.awt.headless=true`. On by default: an embedded VM has no window
  /// to show, and on macOS a non-headless AWT, touched from a thread that is
  /// not the process's main thread, can hang the first time anything
  /// graphical runs — font metrics included. Headless keeps fonts, images and
  /// PDF rendering working; only on-screen windows go.
  final bool headless;

  /// `-Dfile.encoding` and `-Dsun.jnu.encoding` — the default charset and the
  /// one for file names. UTF-8 by default, so neither depends on the locale of
  /// whatever started the process. `null` leaves both to the JVM.
  final String? encoding;

  /// `-Duser.timezone`, the zone `ZoneId.systemDefault()` and `new Date()`
  /// formatting use. `null` leaves it to the host.
  final String? timeZone;

  /// `-Xmx<n>m`. `null` leaves it to the JVM, which takes a quarter of the
  /// machine's memory — or of the container's limit.
  final int? maxHeapMb;

  /// `-Xms<n>m`.
  final int? initialHeapMb;

  /// `false` adds `-XX:-UsePerfData`: no `hsperfdata` file in the temporary
  /// directory, which in a container is only litter. Tools such as `jps` and
  /// `jstat` stop seeing the VM.
  final bool usePerfData;

  /// `-Djava.util.logging.config.file`, the `java.util.logging` configuration
  /// read at startup (see also [JvmJavaLogging.configureJavaLogging]).
  final String? loggingConfigFile;

  /// More `-D<key>=<value>` properties.
  final Map<String, String> systemProperties;

  /// Options passed as they are, after everything else.
  final List<String> extra;

  /// The options, in the order they go to `JNI_CreateJavaVM`.
  ///
  /// `-Djava.class.path` is not one of them: [Jvm.startOrAttach] builds it
  /// from its `classPath`.
  List<String> build() => [
    if (headless) '-Djava.awt.headless=true',
    if (encoding != null) ...[
      '-Dfile.encoding=$encoding',
      '-Dsun.jnu.encoding=$encoding',
    ],
    if (timeZone != null) '-Duser.timezone=$timeZone',
    if (initialHeapMb != null) '-Xms${initialHeapMb}m',
    if (maxHeapMb != null) '-Xmx${maxHeapMb}m',
    if (!usePerfData) '-XX:-UsePerfData',
    if (loggingConfigFile != null)
      '-Djava.util.logging.config.file=$loggingConfigFile',
    for (final MapEntry(:key, :value) in systemProperties.entries)
      '-D$key=$value',
    ...extra,
  ];

  @override
  String toString() => 'JvmOptions${build()}';
}
