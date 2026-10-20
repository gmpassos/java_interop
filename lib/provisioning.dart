/// Getting a package's Java libraries onto the machine, and finding them.
///
/// Kept out of `package:java_interop/java_interop.dart`: the binding itself
/// does not need it, and a program that gets its jars another way never
/// imports it. Like the binding, it depends on nothing beyond the Dart SDK.
///
/// The model: a package describes its Java runtime as a [JavaRuntimeSpec] —
/// a POM it ships, a runtime id, the classes that must (and must not) be in
/// the jars. At build time, [runProvisioningCli] (or [provisionJavaRuntime])
/// has Maven resolve the jars once into a versioned cache directory and
/// [verifyJars] checks them. At runtime, [resolveClassPath] finds them for
/// `Jvm.startOrAttach`:
///
/// ```dart
/// final classPath = resolveClassPath(reportsRuntime);
/// final jvm = Jvm.startOrAttach(
///   classPath: classPath.entries,
///   vmOptions: const JvmOptions().build(),
/// );
/// ```
library;

export 'src/provisioning/class_path_resolver.dart'
    show
        ClassPathSource,
        JavaRuntimeNotProvisioned,
        ResolvedClassPath,
        readRuntimeClassPath,
        resolveClassPath;
export 'src/provisioning/jar_file.dart' show JarFile;
export 'src/provisioning/jar_verifier.dart' show JarVerification, verifyJars;
export 'src/provisioning/java_runtime_spec.dart' show JavaRuntimeSpec;
export 'src/provisioning/provisioner.dart'
    show
        MavenFailed,
        MavenNotFound,
        ProvisionResult,
        locateMaven,
        provisionJavaRuntime,
        readPackagePom,
        runProvisioningCli;
