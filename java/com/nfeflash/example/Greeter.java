package com.nfeflash.example;

/**
 * The example class used by {@code example/greeter/} and the README.
 *
 * <p>Lives in this project rather than alongside that example because the test
 * suite calls it too.
 *
 * <p>Covers the three shapes that matter for real interop: a constructor taking
 * an object, an instance method returning an object, and a static method
 * returning a primitive — plus one that throws.
 */
public class Greeter {

    private final String name;

    public Greeter(String name) {
        this.name = name;
    }

    /** Instance method returning an object. Signature: ()Ljava/lang/String; */
    public String greet() {
        return "Hello, " + name + "! (from Java " + System.getProperty("java.version") + ")";
    }

    /** The name this greeter was constructed with. */
    public String getName() {
        return name;
    }

    /** Static method returning a primitive. Signature: (II)I */
    public static int add(int a, int b) {
        return a + b;
    }

    /** Throws ArithmeticException when b is 0, to exercise exception handling. */
    public static int divide(int a, int b) {
        return a / b;
    }
}
