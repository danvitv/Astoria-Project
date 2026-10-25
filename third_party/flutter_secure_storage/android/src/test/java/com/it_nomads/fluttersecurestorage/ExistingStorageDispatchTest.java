package com.it_nomads.fluttersecurestorage;

import android.content.Context;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.Result;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class ExistingStorageDispatchTest {
    private static class CapturingResult implements Result {
        String code;
        String message;
        Object details;
        boolean succeeded;
        boolean notImplemented;

        @Override public void success(Object value) { succeeded = true; }
        @Override public void error(String code, String message, Object details) {
            this.code = code;
            this.message = message;
            this.details = details;
        }
        @Override public void notImplemented() { notImplemented = true; }
    }

    private static void set(Object target, String name, Object value) throws Exception {
        Field field = target.getClass().getDeclaredField(name);
        field.setAccessible(true);
        field.set(target, value);
    }

    @Test
    @SuppressWarnings("unchecked")
    public void warmCacheCannotGrantPermissionAndDedicatedErrorsAreRedacted() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        FlutterSecureStoragePlugin plugin = new FlutterSecureStoragePlugin();
        set(plugin, "applicationContext", context);
        Field field = FlutterSecureStoragePlugin.class.getDeclaredField("storagesBySharedPreferencesName");
        field.setAccessible(true);
        Map<String, FlutterSecureStorage> cache = (Map<String, FlutterSecureStorage>) field.get(plugin);
        FlutterSecureStorage cached = new FlutterSecureStorage(context) {
            @Override public void initialize(FlutterSecureStorageConfig config, SecurePreferencesCallback<Void> callback) {
                throw new AssertionError("Normal initialization is forbidden");
            }
        };
        cache.put("ns:missing-dispatch-test", cached);
        Map<String, Object> options = new HashMap<>();
        options.put("storageNamespace", "missing-dispatch-test");
        options.put("resetOnError", "true");
        options.put("migrateOnAlgorithmChange", "true");
        Map<String, Object> payload = new HashMap<>();
        payload.put("key", "synthetic-sensitive-key");
        payload.put("options", options);
        CapturingResult result = new CapturingResult();
        plugin.new MethodRunner(new MethodCall("readExisting", payload), result).run();

        assertEquals("READ_EXISTING_FAILED", result.code);
        assertEquals("Existing secure storage is unavailable.", result.message);
        assertNull(result.details);
        assertFalse(result.succeeded);
        assertFalse(result.notImplemented);
        assertEquals(1, cache.size());
        assertSame(cached, cache.get("ns:missing-dispatch-test"));
    }

    @Test
    public void malformedExistingCallDoesNotEnterOrdinaryErrorHandling() {
        FlutterSecureStoragePlugin plugin = new FlutterSecureStoragePlugin();
        CapturingResult result = new CapturingResult();
        plugin.new MethodRunner(new MethodCall("readExisting", "synthetic-sensitive-body"), result).run();
        assertEquals("READ_EXISTING_FAILED", result.code);
        assertEquals("Existing secure storage is unavailable.", result.message);
        assertNull(result.details);
        assertFalse(result.succeeded);
    }
}
