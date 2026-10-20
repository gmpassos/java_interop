package com.nfeflash.example;

/**
 * Fixtures for {@code JavaExecutor} and {@code reflectMethod}.
 *
 * <p>Package-private on purpose: making its methods accessible is what needs
 * {@code JavaExecutor.accessible} on JDK 17+, where {@code setAccessible}
 * called through JNI only works for public members of public classes.
 */
class Tasks extends TasksBase {
    /** Not atomic: two unsynchronized calls lose an increment. */
    static int counter;

    private final String greeting;

    Tasks(String greeting) {
        this.greeting = greeting;
    }

    String greet(String name) {
        return greeting + ", " + name;
    }

    static String sleepThenEcho(String value, long millis) throws InterruptedException {
        Thread.sleep(millis);
        return value;
    }

    static void fail(String message) {
        throw new IllegalStateException(message);
    }

    /** Reads, sleeps, writes: a lost update unless the callers share a monitor. */
    static int slowIncrement(long millis) throws InterruptedException {
        int read = counter;
        Thread.sleep(millis);
        counter = read + 1;
        return counter;
    }

    static String threadName() {
        return Thread.currentThread().getName()
                + (Thread.currentThread().isDaemon() ? " daemon" : "");
    }

    static boolean hasContextClassLoader() {
        return Thread.currentThread().getContextClassLoader() == ClassLoader.getSystemClassLoader();
    }

    static byte[] bytes(int length) {
        byte[] out = new byte[length];
        for (int i = 0; i < length; i++) {
            out[i] = (byte) i;
        }
        return out;
    }

    /** The runtime class of each argument, comma-separated. */
    static String describe(Object[] values) {
        StringBuilder out = new StringBuilder();
        for (Object value : values) {
            if (out.length() > 0) out.append(',');
            out.append(value == null ? "null" : value.getClass().getName());
        }
        return out.toString();
    }

    static String overloaded(int value) {
        return "int";
    }

    static String overloaded(long value) {
        return "long";
    }

    static String overloaded(String[] values) {
        return "String[]";
    }
}

class TasksBase {
    private static String inherited() {
        return "from the base";
    }
}
