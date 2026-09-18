package com.nfeflash.example;

import java.util.Arrays;

/**
 * Every shape the Dart binding claims to support, in one class, so the test
 * suite can exercise the JNI surface end to end.
 *
 * <p>Deliberately exhaustive on primitive types: each of the eight has a
 * distinct JNI accessor with a distinct native signature, and a mistake in any
 * one of them (a {@code Uint8} where an {@code Int8} belongs, a float read as
 * an int) produces a plausible-looking wrong number rather than a crash. The
 * boundary values below — {@code Byte.MIN_VALUE}, {@code Long.MAX_VALUE},
 * negative shorts, non-ASCII chars — are the ones that expose those mistakes.
 */
public class Fixtures {

    // --- Instance fields, one per JNI type ---------------------------------

    public boolean booleanField = true;
    public byte byteField = -128;
    public char charField = 'ç';
    public short shortField = -32768;
    public int intField = 2147483647;
    public long longField = 9223372036854775807L;
    public float floatField = 3.5f;
    public double doubleField = 2.718281828459045;
    public String stringField = "initial";
    public Object objectField = null;
    public int[] intArrayField = {1, 2, 3};
    public Integer boxedIntField = 7;

    // --- Static fields, one per JNI type -----------------------------------

    public static boolean staticBooleanField = false;
    public static byte staticByteField = 127;
    public static char staticCharField = 'A';
    public static short staticShortField = 32767;
    public static int staticIntField = -2147483648;
    public static long staticLongField = -9223372036854775808L;
    public static float staticFloatField = -1.5f;
    public static double staticDoubleField = -0.5;
    public static String staticStringField = "static-initial";

    /** Restores every mutable field to its declared value. */
    public static void resetStatics() {
        staticBooleanField = false;
        staticByteField = 127;
        staticCharField = 'A';
        staticShortField = 32767;
        staticIntField = -2147483648;
        staticLongField = -9223372036854775808L;
        staticFloatField = -1.5f;
        staticDoubleField = -0.5;
        staticStringField = "static-initial";
    }

    // --- Constructors ------------------------------------------------------

    private final String label;
    private final int number;

    public Fixtures() {
        this("default", 0);
    }

    public Fixtures(String label) {
        this(label, 0);
    }

    public Fixtures(String label, int number) {
        this.label = label;
        this.number = number;
    }

    public String getLabel() {
        return label;
    }

    public int getNumber() {
        return number;
    }

    // --- Instance methods, one per JNI return type -------------------------

    public void voidMethod() {
        stringField = "voidMethod called";
    }

    public boolean negate(boolean value) {
        return !value;
    }

    public byte byteIdentity(byte value) {
        return value;
    }

    public char upperCase(char value) {
        return Character.toUpperCase(value);
    }

    public short shortIdentity(short value) {
        return value;
    }

    public int sum(int a, int b) {
        return a + b;
    }

    public long longIdentity(long value) {
        return value;
    }

    public float halveFloat(float value) {
        return value / 2.0f;
    }

    public double halveDouble(double value) {
        return value / 2.0;
    }

    public String concat(String a, String b) {
        return a + b;
    }

    public Object echoObject(Object value) {
        return value;
    }

    /** Accepts every primitive at once, to check jvalue packing order. */
    public String mixed(boolean z, byte b, char c, short s, int i, long j, float f, double d) {
        return z + "|" + b + "|" + c + "|" + s + "|" + i + "|" + j + "|" + f + "|" + d;
    }

    /** Returns null, to check that a null reference round-trips as null. */
    public String nullString() {
        return null;
    }

    // --- Static methods, one per JNI return type ---------------------------

    public static void staticVoidMethod() {
        staticStringField = "staticVoidMethod called";
    }

    public static boolean staticNegate(boolean value) {
        return !value;
    }

    public static byte staticByteIdentity(byte value) {
        return value;
    }

    public static char staticUpperCase(char value) {
        return Character.toUpperCase(value);
    }

    public static short staticShortIdentity(short value) {
        return value;
    }

    public static int staticSum(int a, int b) {
        return a + b;
    }

    public static long staticLongIdentity(long value) {
        return value;
    }

    public static float staticHalveFloat(float value) {
        return value / 2.0f;
    }

    public static double staticHalveDouble(double value) {
        return value / 2.0;
    }

    public static String staticConcat(String a, String b) {
        return a + b;
    }

    public static Object staticEchoObject(Object value) {
        return value;
    }

    // --- Strings -----------------------------------------------------------

    /** Echoes a string back unchanged, for round-trip checks. */
    public static String echoString(String value) {
        return value;
    }

    /** {@code String.length()} — UTF-16 code units, as in Dart. */
    public static int stringLength(String value) {
        return value.length();
    }

    /** The code point at [index], so astral characters can be verified. */
    public static int codePointAt(String value, int index) {
        return value.codePointAt(index);
    }

    // --- Arrays ------------------------------------------------------------

    public static boolean[] booleanArray() {
        return new boolean[] {true, false, true};
    }

    public static byte[] byteArray() {
        return new byte[] {-128, 0, 127};
    }

    public static char[] charArray() {
        return new char[] {'a', 'ç', '中'};
    }

    public static short[] shortArray() {
        return new short[] {-32768, 0, 32767};
    }

    public static int[] intArray() {
        return new int[] {-2147483648, 0, 2147483647};
    }

    public static long[] longArray() {
        return new long[] {-9223372036854775808L, 0L, 9223372036854775807L};
    }

    public static float[] floatArray() {
        return new float[] {-1.5f, 0.0f, 3.5f};
    }

    public static double[] doubleArray() {
        return new double[] {-1.5, 0.0, 2.718281828459045};
    }

    public static String[] stringArray() {
        return new String[] {"one", null, "três"};
    }

    public static int sumInts(int[] values) {
        int total = 0;
        for (int value : values) {
            total += value;
        }
        return total;
    }

    public static String joinStrings(String[] values) {
        return String.join(",", values);
    }

    public static String describeBytes(byte[] values) {
        return Arrays.toString(values);
    }

    public static double sumDoubles(double[] values) {
        double total = 0;
        for (double value : values) {
            total += value;
        }
        return total;
    }

    /** An {@code Integer[]}, with a null element: a boxed array is not a primitive one. */
    public static Integer[] integerArray() {
        return new Integer[] {1, null, 3};
    }

    /** A {@code int[][]}, so the element descriptor is itself an array. */
    public static int[][] nestedIntArray() {
        return new int[][] {{1, 2}, {3}};
    }

    public static int sumNested(int[][] values) {
        int total = 0;
        for (int[] row : values) {
            for (int value : row) {
                total += value;
            }
        }
        return total;
    }

    /** An instance method taking an array, so both call paths are covered. */
    public int sumWithNumber(int[] values) {
        int total = number;
        for (int value : values) {
            total += value;
        }
        return total;
    }

    // --- Boxed primitives --------------------------------------------------

    /** Declares a wrapper, so an argument has to be boxed exactly. */
    public static int unboxInteger(Integer value) {
        return value == null ? -1 : value.intValue();
    }

    /** Returns a declared wrapper, so the result has to be unboxed. */
    public static Integer boxInteger(int value) {
        return Integer.valueOf(value);
    }

    /** Returns a null wrapper, to check that unboxing preserves null. */
    public static Integer nullInteger() {
        return null;
    }

    public static Long boxLong(long value) {
        return Long.valueOf(value);
    }

    public static Double boxDouble(double value) {
        return Double.valueOf(value);
    }

    public static Boolean boxBoolean(boolean value) {
        return Boolean.valueOf(value);
    }

    /**
     * The runtime class of an erased argument, which is how the inference rule
     * for {@code Object} parameters is observed from Dart.
     */
    public static String classOf(Object value) {
        return value == null ? "null" : value.getClass().getName();
    }

    /** Sums an erased list, the shape every generic API actually has. */
    public static int sumList(java.util.List<Integer> values) {
        int total = 0;
        for (Integer value : values) {
            total += value;
        }
        return total;
    }

    // --- Exceptions --------------------------------------------------------

    /** Throws an exception carrying a message. */
    public static void throwIllegalState(String message) {
        throw new IllegalStateException(message);
    }

    /** Throws an exception with a null message, to check the null path. */
    public static void throwWithoutMessage() {
        throw new UnsupportedOperationException();
    }

    /** Throws a checked exception, declared. */
    public static void throwChecked() throws Exception {
        throw new Exception("checked failure");
    }

    /** Throws from a nested frame, so the stack trace has depth. */
    public static int divide(int a, int b) {
        return a / b;
    }

    /** Throws a custom exception type. */
    public static void throwCustom(String message) {
        throw new FixtureException(message);
    }

    /**
     * Throws an exception wrapping two nested causes.
     *
     * <p>The shape libraries produce constantly — {@code catch (Exception e) {
     * throw new Wrapper(e.getMessage(), e); }} — where the class that says what
     * actually went wrong is not the one thrown but one further down the chain.
     */
    public static void throwWithCauses() {
        Exception root = new java.io.IOException("no route to host");
        Exception middle = new IllegalStateException("connect failed", root);
        throw new FixtureException("operation failed", middle);
    }

    /** Throws an exception whose {@code getCause()} returns itself. */
    public static void throwSelfCaused() {
        throw new SelfCaused("loops back to itself");
    }

    /**
     * Throws an exception nested deeper than the cause walk goes, so the depth
     * bound is observable rather than assumed.
     */
    public static void throwDeeplyNested(int depth) {
        Throwable cause = new IllegalArgumentException("bottom");
        for (int i = 0; i < depth; i++) {
            cause = new IllegalStateException("level " + i, cause);
        }
        throw new FixtureException("top", cause);
    }

    // --- Bytes -------------------------------------------------------------

    /**
     * Every byte value 0–255 in order, as Java sees them: signed, so the second
     * half is negative.
     *
     * <p>The whole range matters because sign is where a byte conversion goes
     * wrong, and it goes wrong quietly — 200 arriving as -56 still looks like a
     * number.
     */
    public static byte[] allByteValues() {
        byte[] bytes = new byte[256];
        for (int i = 0; i < 256; i++) {
            bytes[i] = (byte) i;
        }
        return bytes;
    }

    /** Sums a {@code byte[]} as unsigned, to check what Dart actually sent. */
    public static int sumUnsignedBytes(byte[] bytes) {
        int total = 0;
        for (byte b : bytes) {
            total += (b & 0xff);
        }
        return total;
    }

    /** An empty {@code byte[]}: the boundary case for region reads. */
    public static byte[] noBytes() {
        return new byte[0];
    }

    // --- Enums -------------------------------------------------------------

    /** A three-constant enum, to check constant lookup and identity. */
    public enum Flavour {
        SWEET,
        SOUR,
        UMAMI;

        /**
         * A static field of the enum's own type that is not a constant: the
         * shape {@code JavaClass.enumConstant} has to refuse, since it resolves
         * by field name and type and this one resolves fine and is null.
         */
        public static Flavour UNSET = null;

        public String describe() {
            return "flavour:" + name();
        }
    }

    /** Round-trips an enum constant, so identity is checkable from Dart. */
    public static String describeFlavour(Flavour flavour) {
        return flavour == null ? "none" : flavour.describe();
    }

    // --- Native callbacks --------------------------------------------------

    /**
     * Implemented in Dart and bound with {@code RegisterNatives}.
     *
     * <p>Declaring it {@code native} with no Java body is the whole point:
     * calling it before Dart binds it throws {@code UnsatisfiedLinkError}, which
     * makes "the binding did not happen" a distinguishable failure instead of a
     * crash.
     */
    public static native int nativeDouble(int value);

    /**
     * Calls {@link #nativeDouble} from inside a Java frame.
     *
     * <p>The frame is the point. Invoking the native method directly from Dart
     * would only prove the function pointer works; going Dart → Java → Dart
     * proves the callback runs while a JNI call is already in flight on the same
     * thread, which is the case every visitor, comparator and listener needs.
     */
    public static int callNativeDouble(int value) {
        return nativeDouble(value);
    }

    /** Calls {@link #nativeDouble} in a loop, to check nothing accumulates. */
    public static long sumNativeDouble(int count) {
        long total = 0;
        for (int i = 0; i < count; i++) {
            total += nativeDouble(i);
        }
        return total;
    }

    /** Implemented in Dart; the return value decides the order below. */
    public static native int nativeCompare(int a, int b);

    /**
     * Sorts with a comparator that compares in Dart.
     *
     * <p>Verifiable end to end: the JDK's own sort consumes the returned values,
     * so a wrong or ignored return shows up as a wrong order rather than as a
     * silent no-op.
     */
    public static int[] sortWithNativeComparator(int[] values) {
        Integer[] boxed = new Integer[values.length];
        for (int i = 0; i < values.length; i++) {
            boxed[i] = values[i];
        }
        java.util.Arrays.sort(boxed, (a, b) -> nativeCompare(a, b));
        int[] sorted = new int[boxed.length];
        for (int i = 0; i < boxed.length; i++) {
            sorted[i] = boxed[i];
        }
        return sorted;
    }

    /** Implemented in Dart; takes and returns a reference, not a primitive. */
    public static native String nativeShout(String text);

    /** Calls {@link #nativeShout} from a Java frame and appends a marker. */
    public static String callNativeShout(String text) {
        return nativeShout(text) + "!";
    }

    /** Calls a native method that a Dart handler is expected to throw from. */
    public static native void nativeFail(String message);

    /**
     * Calls {@link #nativeFail} and reports what came back.
     *
     * <p>A Dart callback that throws has to surface in Java as a pending
     * exception, or Java would carry on with a bogus return value.
     */
    public static String catchNativeFail(String message) {
        try {
            nativeFail(message);
            return "no exception";
        } catch (Throwable e) {
            return e.getClass().getName() + ": " + e.getMessage();
        }
    }

    /**
     * Implemented in Dart as an *asynchronous* callback, so it returns before
     * Dart has run anything.
     *
     * <p>Takes a {@code long} and nothing else on purpose: an asynchronous
     * callback is handled after this frame is gone, so any reference passed here
     * would already be dead. A number that indexes a Java-side holder survives;
     * a {@code jobject} does not.
     */
    public static native void nativePost(long callId);

    /** Calls {@link #nativePost} from a JVM-owned thread and waits for it. */
    public static void postFromNewThread(long callId)
            throws InterruptedException {
        Thread thread = new Thread(() -> nativePost(callId), "fixtures-poster");
        thread.start();
        thread.join();
    }

    /**
     * Identifies the calling thread as the JVM sees it.
     *
     * <p>A Dart isolate is not pinned to an OS thread: it runs on a thread from a
     * pool and may resume on a different one after an {@code await}. JNI attaches
     * whatever thread calls in, so a different OS thread means a different
     * {@code java.lang.Thread} — which is what a proxy has to compare against to
     * tell a reentrant callback from a foreign-thread one.
     */
    public static String currentThreadName() {
        Thread thread = Thread.currentThread();
        return thread.getName() + "#" + System.identityHashCode(thread);
    }

    /** Runs {@link #callNativeDouble} on a fresh JVM-owned thread. */
    public static int callNativeDoubleOnNewThread(int value)
            throws InterruptedException {
        final int[] result = {-1};
        final Throwable[] failure = {null};
        Thread thread = new Thread(() -> {
            try {
                result[0] = callNativeDouble(value);
            } catch (Throwable e) {
                failure[0] = e;
            }
        }, "fixtures-native-caller");
        thread.start();
        thread.join();
        if (failure[0] != null) {
            throw new FixtureException(
                    "callback from a foreign thread failed: " + failure[0], failure[0]);
        }
        return result[0];
    }

    // --- Proxies -----------------------------------------------------------

    /** Runs [runnable] here and now, on the caller's thread. */
    public static void run(Runnable runnable) {
        runnable.run();
    }

    /** Runs [runnable] and reports what it threw, if anything. */
    public static String runCatching(Runnable runnable) {
        try {
            runnable.run();
            return "no exception";
        } catch (Throwable e) {
            return e.getClass().getName() + ": " + e.getMessage();
        }
    }

    /** Runs [runnable] on a JVM-owned thread and waits for that thread. */
    public static void runOnNewThread(Runnable runnable)
            throws InterruptedException {
        Thread thread = new Thread(runnable, "fixtures-runner");
        thread.start();
        thread.join();
    }

    /**
     * Compares on a JVM-owned thread and reports the outcome as text.
     *
     * <p>The interesting answer is the failure: a comparator implemented in Dart
     * cannot answer from a thread the JVM owns, and has to say so rather than
     * block.
     */
    public static String compareOnNewThread(
            java.util.Comparator<Object> comparator, Object a, Object b)
            throws InterruptedException {
        final String[] outcome = {"nothing happened"};
        Thread thread = new Thread(() -> {
            try {
                outcome[0] = "compared: " + comparator.compare(a, b);
            } catch (Throwable e) {
                outcome[0] = e.getClass().getName() + ": " + e.getMessage();
            }
        }, "fixtures-comparer");
        thread.start();
        thread.join();
        return outcome[0];
    }

    /**
     * One method per return type, so a proxy's coercion is checked at every
     * width.
     *
     * <p>Dart has one integer type and one float type, so a handler returning
     * {@code 1} cannot say whether it means a {@code byte} or a {@code long};
     * the declared type has to decide.
     */
    public interface Widths {
        boolean asBoolean();

        byte asByte();

        char asChar();

        short asShort();

        int asInt();

        long asLong();

        float asFloat();

        double asDouble();

        String asString();

        Object asObject();
    }

    /** Calls every method of [widths] and reports the values Java received. */
    public static String describeWidths(Widths widths) {
        return widths.asBoolean()
                + "," + widths.asByte()
                + "," + widths.asChar()
                + "," + widths.asShort()
                + "," + widths.asInt()
                + "," + widths.asLong()
                + "," + widths.asFloat()
                + "," + widths.asDouble()
                + "," + widths.asString()
                + "," + widths.asObject();
    }

    /** Where {@link #hold} parks a proxy so Java outlives Dart's handle to it. */
    private static Runnable held;

    /**
     * Keeps a reference to [runnable] on the Java side.
     *
     * <p>The way to reach the case that matters for lifetime: Dart releases its
     * proxy while a Java library is still holding the object. Calling it then has
     * to fail in Java, not jump into freed code.
     */
    public static void hold(Runnable runnable) {
        held = runnable;
    }

    /** Runs whatever {@link #hold} parked, reporting what it threw. */
    public static String runHeld() {
        return runCatching(held);
    }

    /**
     * Runs whatever {@link #hold} parked, on a JVM-owned thread.
     *
     * <p>The combination that has no good answer: a proxy Dart has released,
     * called from a thread Dart does not own. The call can only be queued, and by
     * the time Dart looks at it there is neither a handler to run it nor anyone
     * to report to.
     */
    public static String runHeldOnNewThread() throws InterruptedException {
        final String[] outcome = {"nothing happened"};
        Thread thread = new Thread(
                () -> outcome[0] = runCatching(held), "fixtures-held-runner");
        thread.start();
        thread.join();
        return outcome[0];
    }

    /** {@code String.valueOf(value)}, i.e. its {@code toString}. */
    public static String textOf(Object value) {
        return String.valueOf(value);
    }

    /** {@code value.hashCode()}. */
    public static int hashOf(Object value) {
        return value.hashCode();
    }

    /** {@code a.equals(b)}. */
    public static boolean equalsOf(Object a, Object b) {
        return a.equals(b);
    }

    /**
     * Round-trips [value] through a {@link java.util.HashSet}.
     *
     * <p>Both a hash and an equality check, which is where a proxy with no
     * defaults for the {@code Object} methods falls over.
     */
    public static boolean survivesAHashSet(Object value) {
        java.util.Set<Object> set = new java.util.HashSet<>();
        set.add(value);
        return set.contains(value);
    }

    /** Calls {@code compare} [count] times, to measure a proxy under load. */
    public static int compareRepeatedly(
            java.util.Comparator<Object> comparator, Object a, Object b, int count) {
        int last = 0;
        for (int i = 0; i < count; i++) {
            last = comparator.compare(a, b);
        }
        return last;
    }

    /** A nested class, to check the {@code $} naming rule. */
    public static class Nested {
        public static String hello() {
            return "from Nested";
        }
    }

    /** A project-specific throwable, to check class-name reporting. */
    public static class FixtureException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public FixtureException(String message) {
            super(message);
        }

        public FixtureException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    /**
     * A throwable that returns itself from {@code getCause()}.
     *
     * <p>{@code initCause} forbids this, but overriding the getter does not, so a
     * cause walk that only counts depth would still spin here.
     */
    public static class SelfCaused extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public SelfCaused(String message) {
            super(message);
        }

        @Override
        public synchronized Throwable getCause() {
            return this;
        }
    }
}
