package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.util.Base64;

import com.it_nomads.fluttersecurestorage.ciphers.StorageCipher;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.io.File;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class ExistingStorageReaderTest {
    private Context context;
    private Context readOnlyContext;
    private FlutterSecureStorageConfig config;
    private SharedPreferences data;
    private SharedPreferences keys;
    private SharedPreferences markers;
    private Map<String, Object> options;
    private final List<String> opened = new ArrayList<>();
    private int loads;
    private byte[] decoded;

    @Before
    public void setUp() {
        context = RuntimeEnvironment.getApplication();
        options = new HashMap<>();
        options.put("storageNamespace", "existing-reader-test");
        options.put("preferencesKeyPrefix", "test-prefix");
        options.put("resetOnError", "true");
        options.put("migrateOnAlgorithmChange", "true");
        options.put("migrateWithBackup", "true");
        config = new FlutterSecureStorageConfig(options);
        data = prefs(config.getEffectiveDataPrefsName());
        keys = prefs(config.getEffectiveKeyStoragePrefsName());
        markers = prefs("FlutterSecureStorageConfiguration:" + config.getEffectiveDataPrefsName());
        assertTrue(data.edit().clear().putString("test-prefix_token", Base64.encodeToString(new byte[28], Base64.DEFAULT)).commit());
        assertTrue(keys.edit().clear().putString("synthetic-material", "present").commit());
        assertTrue(markers.edit().clear()
                .putString("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding")
                .putString("FlutterSecureSAlgorithmStorage", "AES_GCM_NoPadding").commit());
        decoded = "synthetic credential".getBytes(StandardCharsets.UTF_8);
        readOnlyContext = new ContextWrapper(context) {
            @Override public SharedPreferences getSharedPreferences(String name, int mode) {
                opened.add(name);
                SharedPreferences original = prefs(name);
                return (SharedPreferences) Proxy.newProxyInstance(SharedPreferences.class.getClassLoader(),
                        new Class<?>[]{SharedPreferences.class}, (proxy, method, args) -> {
                            if ("edit".equals(method.getName())) throw new AssertionError("Preference editing is forbidden");
                            try {
                                return method.invoke(original, args);
                            } catch (InvocationTargetException e) {
                                throw e.getCause();
                            }
                        });
            }
        };
    }

    private SharedPreferences prefs(String name) {
        return context.getSharedPreferences(name, Context.MODE_PRIVATE);
    }

    private Map<String, Object> payload(String key) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("key", key);
        payload.put("options", options);
        return payload;
    }

    private ExistingStorageReader reader() {
        return new ExistingStorageReader(readOnlyContext, (ctx, savedMarkers, effectiveConfig, keyEntries) -> {
            loads++;
            assertEquals(config.getEffectiveDataPrefsName(), effectiveConfig.getEffectiveDataPrefsName());
            assertEquals(config.getEffectiveKeyStoragePrefsName(), effectiveConfig.getEffectiveKeyStoragePrefsName());
            assertEquals(config.getKeyAliasSuffix(), effectiveConfig.getKeyAliasSuffix());
            return new StorageCipher() {
                @Override public byte[] encrypt(byte[] input) { throw new AssertionError("Encryption is forbidden"); }
                @Override public byte[] decrypt(byte[] input) { return decoded; }
                @Override public void deleteKey(Context ctx) { throw new AssertionError("Key deletion is forbidden"); }
            };
        });
    }

    @Test
    public void readsOnlySameNamespaceAndUsesPersistedAlgorithmsNotCallerPreferences() throws Exception {
        options.put("keyCipherAlgorithm", "invented-caller-algorithm");
        options.put("storageCipherAlgorithm", "invented-caller-algorithm");
        Map<String, ?> dataBefore = data.getAll();
        Map<String, ?> keysBefore = keys.getAll();
        Map<String, ?> markersBefore = markers.getAll();
        assertEquals("synthetic credential", reader().read(payload("token")));
        assertEquals(1, loads);
        assertTrue(opened.isEmpty());
        assertEquals(dataBefore, data.getAll());
        assertEquals(keysBefore, keys.getAll());
        assertEquals(markersBefore, markers.getAll());
    }

    @Test
    public void absentEntryRequiresBackendValidationAndCipherConstructionFirst() throws Exception {
        assertNull(reader().read(payload("absent")));
        assertEquals(1, loads);
        ExistingStorageReader unavailable = new ExistingStorageReader(readOnlyContext, (ctx, saved, cfg, keyEntries) -> {
            throw new IllegalStateException("synthetic unavailable backend");
        });
        assertThrows(Exception.class, () -> unavailable.read(payload("absent")));
    }

    @Test
    public void legacyGlobalAndDataMarkersCannotSupplyMissingBackendMarkers() {
        assertTrue(markers.edit().remove("FlutterSecureSAlgorithmKey").commit());
        assertTrue(prefs("FlutterSecureStorageConfiguration").edit()
                .putString("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding").commit());
        assertTrue(data.edit().putString("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding").commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertEquals(0, loads);
        assertFalse(markers.contains("FlutterSecureSAlgorithmKey"));
        assertFalse(opened.contains("FlutterSecureStorageConfiguration"));
    }

    @Test
    public void unsupportedBiometricAndEncryptedPreferencesFailBeforeCipherConstruction() {
        assertTrue(markers.edit().putString("FlutterSecureSAlgorithmKey", "AES_GCM_NoPadding").commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertEquals(0, loads);
        options.put("enforceBiometrics", "true");
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        options.remove("enforceBiometrics");
        options.put("encryptedSharedPreferences", "true");
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertEquals(0, loads);
    }

    @Test
    public void migrationAndEspArtifactsAreNeverRecovered() {
        assertTrue(markers.edit().putString("FlutterSecureStorageBackupStatus", "complete").commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertTrue(markers.edit().remove("FlutterSecureStorageBackupStatus").commit());
        assertTrue(data.edit().putString("test-prefix_token_BACKUP", "synthetic backup").commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertTrue(data.edit().remove("test-prefix_token_BACKUP").commit());
        assertTrue(data.edit().putString("__androidx_security_crypto_encrypted_prefs_key_keyset__", "synthetic legacy").commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertEquals(0, loads);
    }

    @Test
    public void absentPersistedPrefsAndBakRecoveryAreRejectedWithoutOpeningPreferences() throws Exception {
        options.put("storageNamespace", "does-not-exist");
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertTrue(opened.isEmpty());
        options.put("storageNamespace", config.getStorageNamespace());
        File backup = new File(context.getApplicationInfo().dataDir,
                "shared_prefs/" + config.getEffectiveDataPrefsName() + ".xml.bak");
        assertTrue(backup.createNewFile());
        try {
            assertThrows(Exception.class, () -> reader().read(payload("token")));
            assertTrue(opened.isEmpty());
            assertTrue(backup.isFile());
        } finally {
            assertTrue(backup.delete());
        }
    }

    @Test
    public void malformedValuesAndUtf8FailClosedButEmptyPlaintextIsValid() throws Exception {
        assertTrue(data.edit().putString("test-prefix_token", "!").commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertTrue(data.edit().putInt("test-prefix_token", 7).commit());
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertTrue(data.edit().putString("test-prefix_token", Base64.encodeToString(new byte[28], Base64.DEFAULT)).commit());
        decoded = new byte[]{(byte) 0xC3, 0x28};
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        decoded = new byte[0];
        assertEquals("", reader().read(payload("token")));
    }

    @Test
    public void malformedPayloadAndNonCanonicalAuthenticationFlagsAreRejected() {
        assertThrows(Exception.class, () -> reader().read(null));
        assertThrows(Exception.class, () -> reader().read("not-a-map"));
        Map<String, Object> badKey = payload("token");
        badKey.put("key", 123);
        assertThrows(Exception.class, () -> reader().read(badKey));
        options.put("enforceBiometrics", "TRUE");
        assertThrows(Exception.class, () -> reader().read(payload("token")));
        assertEquals(0, loads);
        assertTrue(opened.isEmpty());
    }

    @Test
    public void cachedPreferencesCannotConcealCorruptPersistedXml() throws Exception {
        File file = new File(context.getApplicationInfo().dataDir,
                "shared_prefs/" + config.getEffectiveDataPrefsName() + ".xml");
        byte[] before = Files.readAllBytes(file.toPath());
        Map<String, ?> cached = data.getAll();
        Files.write(file.toPath(), "<map><string name=\"broken\">".getBytes(StandardCharsets.UTF_8));
        try {
            assertThrows(Exception.class, () -> reader().read(payload("token")));
            assertEquals(0, loads);
            assertEquals(cached, data.getAll());
            assertTrue(opened.isEmpty());
        } finally {
            Files.write(file.toPath(), before);
        }
    }
}
