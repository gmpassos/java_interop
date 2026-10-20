package dart.jni;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongConsumer;

/**
 * Runs Java calls on a pool of JVM threads for a Dart isolate.
 *
 * <p>Every JNI call blocks the isolate that makes it until it returns, so a slow
 * call made directly — a network round-trip, a report render — freezes the
 * isolate's event loop for as long as it takes. Instead, the isolate submits
 * the call here and goes on serving its event loop: the call runs on a pool
 * thread, its outcome is parked under an id, and {@link LongConsumer#accept}
 * tells Dart the id. Dart then calls {@link #take} to collect the result, or to
 * have the original exception thrown back at it.
 *
 * <p>The {@link LongConsumer} is a Dart proxy. Called from a pool thread, the
 * binding queues the call onto the isolate's event loop, so the pool thread
 * never waits for Dart.
 *
 * <p>A call is a reflective {@link Method} — made accessible with
 * {@link #accessible} when it is not public — and, when given a monitor, holds
 * it for the call. That is how a library with global state is used from many
 * threads: the calls that touch the state share a monitor, and the others run
 * in parallel.
 *
 * <p>Loaded at runtime from bytes embedded in the Dart package (see
 * {@code bin/embed_java.dart}): no jar to ship. It uses JDK types only, so it
 * can live in its own class loader.
 */
public final class JavaExecutor {
    private final ExecutorService pool;
    private final LongConsumer done;

    private final AtomicLong nextId = new AtomicLong(1);

    /** {@code {result, null}} or {@code {null, throwable}}, by task id. */
    private final Map<Long, Object[]> outcomes = new ConcurrentHashMap<>();

    public JavaExecutor(String name, int threads, LongConsumer done) {
        if (threads < 1) {
            throw new IllegalArgumentException("threads must be at least 1: " + threads);
        }
        this.done = done;

        AtomicInteger next = new AtomicInteger(1);
        ClassLoader loader = ClassLoader.getSystemClassLoader();
        this.pool = Executors.newFixedThreadPool(threads, task -> {
            Thread thread = new Thread(task, name + "-" + next.getAndIncrement());
            thread.setDaemon(true);
            // JAXB, StAX, Axis2, JasperReports and ServiceLoader discover
            // implementations through the context class loader. A pool thread
            // would inherit whatever the creating thread had — on a thread the
            // binding attached, possibly nothing — so it is set explicitly, to
            // the loader the application's class path is on.
            thread.setContextClassLoader(loader);
            return thread;
        });
    }

    /**
     * Runs {@code method.invoke(target, args)} on a pool thread and returns the
     * task id at once.
     *
     * @param target {@code null} for a static method
     * @param monitor held for the whole call when not {@code null}
     */
    public long submit(Method method, Object target, Object[] args, Object monitor) {
        long id = nextId.getAndIncrement();
        Runnable task = () -> {
            Object[] outcome;
            try {
                Object result;
                if (monitor != null) {
                    synchronized (monitor) {
                        result = method.invoke(target, args);
                    }
                } else {
                    result = method.invoke(target, args);
                }
                outcome = new Object[] {result, null};
            } catch (InvocationTargetException e) {
                Throwable cause = e.getCause();
                outcome = new Object[] {null, cause != null ? cause : e};
            } catch (Throwable e) {
                outcome = new Object[] {null, e};
            }
            outcomes.put(id, outcome);
            try {
                done.accept(id);
            } catch (Throwable e) {
                // The Dart side is gone (shut down mid-task): nobody will take
                // this outcome.
                outcomes.remove(id);
            }
        };
        pool.execute(task);
        return id;
    }

    /**
     * The result of task {@code id}, or its exception, thrown as is. Each id
     * can be taken once.
     */
    public Object take(long id) throws Throwable {
        Object[] outcome = outcomes.remove(id);
        if (outcome == null) {
            throw new IllegalStateException("task " + id + " is not done, or was already taken");
        }
        if (outcome[1] != null) {
            throw (Throwable) outcome[1];
        }
        return outcome[0];
    }

    /**
     * Makes {@code method} accessible, from Java.
     *
     * <p>Since JDK 17, {@code setAccessible(true)} called through JNI from a
     * thread with no Java frame only works for public members of public classes
     * in exported packages. Called from here, the caller is this class, and a
     * class path's unnamed module is open to it.
     */
    public static Method accessible(Method method) {
        method.setAccessible(true);
        return method;
    }

    /** Whether task {@code id} is done and its outcome not taken yet. */
    public boolean isDone(long id) {
        return outcomes.containsKey(id);
    }

    /** Outcomes parked and not taken yet. */
    public int parked() {
        return outcomes.size();
    }

    /** Stops taking tasks and waits up to {@code timeoutMillis} for the running ones. */
    public boolean shutdown(long timeoutMillis) throws InterruptedException {
        pool.shutdown();
        return pool.awaitTermination(timeoutMillis, TimeUnit.MILLISECONDS);
    }
}
