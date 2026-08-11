package dart.jni;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Routes calls on a {@link Proxy} to a Dart function.
 *
 * <p>This class exists because {@code Proxy.newProxyInstance} needs a Java
 * {@link InvocationHandler} and {@code RegisterNatives} needs a Java class to
 * hang a native method on — neither can be conjured from Dart. It is compiled by
 * {@code tool/gen_proxy_class.sh} into {@code lib/src/proxy_class.g.dart} as
 * bytes and loaded at runtime with JNI {@code DefineClass}, so the Dart package
 * still ships no jar and depends on no build step.
 *
 * <p>Keep it small and dependency-free: it is loaded into a bare class loader
 * and can see nothing but {@code java.base}.
 *
 * <h2>Which thread is calling</h2>
 *
 * <p>The thread check below is the reason this logic is in Java rather than in
 * the Dart trampoline. A Dart {@code isolateLocal} callback invoked from a
 * thread that is not its isolate's aborts the whole process — "Cannot invoke
 * native callback outside an isolate" — <em>before</em> any Dart code runs, so
 * Dart cannot defend itself. Java can, because {@link Thread#currentThread()}
 * is free and reliable here.
 *
 * <p>So: same thread as the isolate's means a reentrant call, dispatched
 * synchronously with a return value. Any other thread means the arguments cannot
 * be handed over directly — a Dart {@code listener} callback runs after this
 * frame is gone, and by then every {@code jobject} in it is dead. They are
 * parked in {@link #PENDING} under a numeric id instead, and Dart fetches them
 * from its own thread with {@link #takePending}.
 *
 * <p>Which thread <em>is</em> the isolate's is not fixed once and for all. An
 * isolate runs on a thread from a pool, and it can resume on a different one —
 * awaiting an {@code Isolate.run} is enough to move the main isolate onto the
 * thread the child has just freed. So {@link #owner} is re-read from Dart via
 * {@link #rebindAll}, and it is deliberately only ever *narrowing*: Java's own
 * {@code Thread} comparison decides, and can at worst refuse a call that would
 * have worked, never accept one that aborts the process.
 */
public final class DartInvocationHandler implements InvocationHandler {
    private static final Object[] NO_ARGS = new Object[0];

    /** Calls parked for the Dart isolate to pick up, by call id. */
    private static final Map<Long, Object[]> PENDING = new ConcurrentHashMap<>();

    private static final AtomicLong NEXT_CALL_ID = new AtomicLong(1);

    /**
     * A ceiling on parked calls, so a blocked or dead isolate fails loudly
     * instead of growing the map until the heap runs out.
     */
    private static final int MAX_PENDING = 1024;

    /**
     * Every live handler defined by this class, by token.
     *
     * <p>The class is loaded once per Dart isolate, in a class loader of its own,
     * so every handler in here belongs to the same isolate and moves threads
     * together — which is what lets {@link #rebindAll} fix them all in one call.
     */
    private static final Map<Long, DartInvocationHandler> HANDLERS =
            new ConcurrentHashMap<>();

    /** Identifies the Dart-side handler; meaningless to Java. */
    private final long token;

    /** The thread the Dart isolate was last seen running on. */
    private volatile Thread owner;

    private final boolean forwardObjectMethods;

    private DartInvocationHandler(long token, boolean forwardObjectMethods) {
        this.token = token;
        this.owner = Thread.currentThread();
        this.forwardObjectMethods = forwardObjectMethods;
        HANDLERS.put(token, this);
    }

    /**
     * Records the calling thread as the isolate's, for every handler here.
     *
     * <p>Called from Dart when it notices its {@code JNIEnv*} — which is
     * per-thread, and so a free thread identity — has changed.
     */
    public static void rebindAll() {
        Thread current = Thread.currentThread();
        for (DartInvocationHandler handler : HANDLERS.values()) {
            handler.owner = current;
        }
    }

    /** Drops the handler for [token]; called when Dart releases its proxy. */
    public static void forget(long token) {
        HANDLERS.remove(token);
    }

    /** How many handlers are live; for diagnostics and tests. */
    public static int handlerCount() {
        return HANDLERS.size();
    }

    /**
     * Builds a proxy implementing {@code interfaceNames}, routing to the Dart
     * handler identified by {@code token}.
     *
     * <p>One call so Dart pays one JNI round trip instead of four, and so the
     * handler's owner thread is recorded on the thread that is actually driving
     * it.
     */
    public static Object newProxy(
            String[] interfaceNames, long token, boolean forwardObjectMethods)
            throws ClassNotFoundException {
        ClassLoader loader = DartInvocationHandler.class.getClassLoader();

        Class<?>[] interfaces = new Class<?>[interfaceNames.length];
        for (int i = 0; i < interfaceNames.length; i++) {
            String name = interfaceNames[i].replace('/', '.');
            // The three-argument form on purpose: Class.forName(String) is
            // caller-sensitive and there is no Java frame to inspect under JNI.
            Class<?> type = Class.forName(name, false, loader);
            if (!type.isInterface()) {
                throw new IllegalArgumentException(
                        name + " is not an interface; a proxy can only implement"
                                + " interfaces");
            }
            interfaces[i] = type;
        }

        InvocationHandler handler =
                new DartInvocationHandler(token, forwardObjectMethods);
        try {
            return Proxy.newProxyInstance(loader, interfaces, handler);
        } catch (IllegalArgumentException e) {
            // This loader cannot see every interface — try the one that owns
            // the first, which covers interfaces loaded by an application
            // loader of its own.
            if (interfaces.length == 0) {
                throw e;
            }
            return Proxy.newProxyInstance(
                    interfaces[0].getClassLoader(), interfaces, handler);
        }
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) {
        Object[] arguments = args == null ? NO_ARGS : args;

        if (!forwardObjectMethods && method.getDeclaringClass() == Object.class) {
            return objectMethod(proxy, method, arguments);
        }

        if (Thread.currentThread() == owner) {
            return coerce(method.getReturnType(), invokeSync(token, method, arguments));
        }

        if (method.getReturnType() != void.class) {
            throw new IllegalStateException(
                    "cannot answer "
                            + method.getDeclaringClass().getName()
                            + "."
                            + method.getName()
                            + " from thread '"
                            + Thread.currentThread().getName()
                            + "': the Dart handler belongs to thread '"
                            + owner.getName()
                            + "', and waiting there for a value can deadlock."
                            + " Only void methods may be called from a"
                            + " JVM-owned thread. (If this *is* the isolate's"
                            + " thread and it moved, call"
                            + " JavaProxy.bindCurrentThread() from Dart first.)");
        }

        if (PENDING.size() >= MAX_PENDING) {
            throw new IllegalStateException(
                    "Dart is not consuming asynchronous proxy calls: "
                            + PENDING.size()
                            + " are queued. Is the isolate blocked or gone?");
        }

        long callId = NEXT_CALL_ID.getAndIncrement();
        PENDING.put(callId, new Object[] {method, arguments});
        invokeAsync(token, callId);
        return null;
    }

    /**
     * Answers {@code equals}, {@code hashCode} and {@code toString} here.
     *
     * <p>{@link Proxy} routes those three to the handler like any other method.
     * Without defaults a proxy would break the moment it went into a
     * {@code HashMap} or a log line, for reasons that look nothing like the
     * cause.
     */
    private Object objectMethod(Object proxy, Method method, Object[] args) {
        switch (method.getName()) {
            case "equals":
                return proxy == args[0];
            case "hashCode":
                return System.identityHashCode(proxy);
            case "toString":
                StringBuilder out = new StringBuilder("DartProxy[");
                Class<?>[] interfaces = proxy.getClass().getInterfaces();
                for (int i = 0; i < interfaces.length; i++) {
                    if (i > 0) {
                        out.append(", ");
                    }
                    out.append(interfaces[i].getName());
                }
                return out.append("]@")
                        .append(Integer.toHexString(System.identityHashCode(proxy)))
                        .toString();
            default:
                return coerce(
                        method.getReturnType(), invokeSync(token, method, args));
        }
    }

    /**
     * Narrows what Dart returned to the method's declared type.
     *
     * <p>Dart has one integer type and one float type, so it cannot know whether
     * {@code 1} should arrive as a {@code Byte}, {@code Short}, {@code Integer}
     * or {@code Long} — and {@link Proxy} throws {@code ClassCastException} for
     * the wrong wrapper, naming neither the method nor the value. Doing the
     * narrowing here means Dart returns any {@code Number} and this decides.
     */
    private static Object coerce(Class<?> type, Object value) {
        if (type == void.class || !type.isPrimitive()) {
            return value;
        }
        if (value == null) {
            throw new NullPointerException(
                    "the Dart handler returned null for a method declared to"
                            + " return " + type.getName());
        }
        if (type == boolean.class) {
            return value;
        }
        if (type == char.class) {
            return value instanceof Character
                    ? value
                    : (char) ((Number) value).intValue();
        }
        if (!(value instanceof Number)) {
            throw new ClassCastException(
                    "the Dart handler returned a "
                            + value.getClass().getName()
                            + " for a method declared to return "
                            + type.getName());
        }
        Number number = (Number) value;
        if (type == int.class) {
            return number.intValue();
        }
        if (type == long.class) {
            return number.longValue();
        }
        if (type == double.class) {
            return number.doubleValue();
        }
        if (type == float.class) {
            return number.floatValue();
        }
        if (type == short.class) {
            return number.shortValue();
        }
        if (type == byte.class) {
            return number.byteValue();
        }
        return value;
    }

    /**
     * Hands the parked call {@code callId} to Dart as {@code {method, args}},
     * removing it. Returns {@code null} if it was already taken.
     */
    public static Object[] takePending(long callId) {
        return PENDING.remove(callId);
    }

    /** How many calls are parked; for diagnostics and tests. */
    public static int pendingCount() {
        return PENDING.size();
    }

    /** Drops every parked call, for a Dart side that is shutting down. */
    public static int discardPending() {
        int size = PENDING.size();
        PENDING.clear();
        return size;
    }

    /** Bound from Dart with {@code RegisterNatives}; runs the handler now. */
    private static native Object invokeSync(long token, Method method, Object[] args);

    /** Bound from Dart with {@code RegisterNatives}; queues the call. */
    private static native void invokeAsync(long token, long callId);
}
