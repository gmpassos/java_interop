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
    }
}
