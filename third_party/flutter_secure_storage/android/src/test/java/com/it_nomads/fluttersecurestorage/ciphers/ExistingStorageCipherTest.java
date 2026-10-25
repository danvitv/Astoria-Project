package com.it_nomads.fluttersecurestorage.ciphers;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.util.Base64;

import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.util.HashMap;
import java.util.Map;

import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

/** Synthetic unwrap provider; exercises the real upstream AES-GCM implementation. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class ExistingStorageCipherTest {
    private Context context;
    private Context readOnlyContext;
    private FlutterSecureStorageConfig config;
    private SharedPreferences keyPrefs;

    private static class FakeKeyCipher implements KeyCipher {
        boolean denyWrites;

        @Override public byte[] wrap(Key key) {
            if (denyWrites) throw new AssertionError("Key wrapping is forbidden");
            return key.getEncoded();
        }
        @Override public Key unwrap(byte[] wrappedKey, String algorithm) {
            return new SecretKeySpec(wrappedKey, algorithm);
        }
        @Override public Cipher getCipher(Context context) { return null; }
        @Override public void deleteKey() { throw new AssertionError("Key deletion is forbidden"); }
    }

    @Before
    public void setUp() {
        context = RuntimeEnvironment.getApplication();
        config = new FlutterSecureStorageConfig(new HashMap<>());
        keyPrefs = context.getSharedPreferences(config.getEffectiveKeyStoragePrefsName(), Context.MODE_PRIVATE);
        keyPrefs.edit().clear().commit();
        readOnlyContext = new ContextWrapper(context) {
            @Override public SharedPreferences getSharedPreferences(String name, int mode) {
                SharedPreferences original = context.getSharedPreferences(name, mode);
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

    private StorageCipher existing(KeyCipher keyCipher) throws Exception {
        String wrappedKey = readOnlyContext.getSharedPreferences(config.getEffectiveKeyStoragePrefsName(), Context.MODE_PRIVATE)
                .getString(StorageCipherImplementationGCM.WRAPPED_KEY_PREF, null);
        return new StorageCipherImplementationGCM(keyCipher, config, wrappedKey);
    }

    @Test
    public void ordinaryCiphertextAndKeyRemainReadableWithoutAnyEditorOrWrapping() throws Exception {
        FakeKeyCipher keyCipher = new FakeKeyCipher();
        StorageCipher ordinary = new StorageCipherImplementationGCM(context, keyCipher, null, config);
        byte[] plaintext = "synthetic credential".getBytes(StandardCharsets.UTF_8);
        byte[] encrypted = ordinary.encrypt(plaintext);
        Map<String, ?> before = keyPrefs.getAll();
        keyCipher.denyWrites = true;

        StorageCipher reader = existing(keyCipher);
        assertArrayEquals(plaintext, reader.decrypt(encrypted));
        assertThrows(Exception.class, () -> reader.encrypt(plaintext));
        assertThrows(IllegalStateException.class, () -> reader.deleteKey(readOnlyContext));
        assertEquals(before, keyPrefs.getAll());
        // The ordinary constructor and write path are still usable after the read.
        StorageCipher later = new StorageCipherImplementationGCM(context, keyCipher, null, config);
        assertArrayEquals(plaintext, later.decrypt(later.encrypt(plaintext)));
    }

    @Test
    public void missingAndLegacyOnlyWrappedKeysFailWithoutGeneratingOrAdopting() {
        FakeKeyCipher keyCipher = new FakeKeyCipher();
        keyCipher.denyWrites = true;
        assertThrows(Exception.class, () -> existing(keyCipher));
        keyPrefs.edit().putString(StorageCipherImplementationGCM.LEGACY_V9_KEY,
                Base64.encodeToString(new byte[16], Base64.DEFAULT)).commit();
        Map<String, ?> before = keyPrefs.getAll();
        assertThrows(Exception.class, () -> existing(keyCipher));
        assertEquals(before, keyPrefs.getAll());
    }

    @Test
    public void corruptWrongSizeAndInvalidatedMaterialFailWithoutRepair() {
        FakeKeyCipher keyCipher = new FakeKeyCipher();
        keyCipher.denyWrites = true;
        keyPrefs.edit().putString(StorageCipherImplementationGCM.WRAPPED_KEY_PREF, "!").commit();
        Map<String, ?> corrupt = keyPrefs.getAll();
        assertThrows(Exception.class, () -> existing(keyCipher));
        assertEquals(corrupt, keyPrefs.getAll());
        keyPrefs.edit().putString(StorageCipherImplementationGCM.WRAPPED_KEY_PREF,
                Base64.encodeToString(new byte[3], Base64.DEFAULT)).commit();
        Map<String, ?> wrongSize = keyPrefs.getAll();
        assertThrows(Exception.class, () -> existing(keyCipher));
        assertEquals(wrongSize, keyPrefs.getAll());
        FakeKeyCipher invalidated = new FakeKeyCipher() {
            @Override public Key unwrap(byte[] key, String algorithm) {
                throw new IllegalStateException("synthetic invalidated key");
            }
        };
        assertThrows(Exception.class, () -> existing(invalidated));
        assertEquals(wrongSize, keyPrefs.getAll());
    }

    @Test
    public void authenticationFailureDoesNotRepairOrDeleteMaterial() throws Exception {
        FakeKeyCipher keyCipher = new FakeKeyCipher();
        StorageCipher ordinary = new StorageCipherImplementationGCM(context, keyCipher, null, config);
        byte[] encrypted = ordinary.encrypt(new byte[0]);
        encrypted[encrypted.length - 1] ^= 1;
        Map<String, ?> before = keyPrefs.getAll();
        keyCipher.denyWrites = true;
        StorageCipher reader = existing(keyCipher);
        assertThrows(Exception.class, () -> reader.decrypt(encrypted));
        assertEquals(before, keyPrefs.getAll());
    }

    @Test
    public void algorithmsMustBeExplicitModernBackendMarkers() {
        Map<String, Object> markers = new HashMap<>();
        assertThrows(Exception.class, () -> StorageCipherFactory.validateExistingAlgorithms(markers));
        markers.put("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding");
        assertThrows(Exception.class, () -> StorageCipherFactory.validateExistingAlgorithms(markers));
        markers.put("FlutterSecureSAlgorithmStorage", "AES_CBC_PKCS7Padding");
        assertThrows(Exception.class, () -> StorageCipherFactory.validateExistingAlgorithms(markers));
        markers.put("FlutterSecureSAlgorithmStorage", "AES_GCM_NoPadding");
        markers.put("FlutterSecureSAlgorithmKey", "AES_GCM_NoPadding_BIOMETRIC");
        assertThrows(Exception.class, () -> StorageCipherFactory.validateExistingAlgorithms(markers));
        markers.put("FlutterSecureSAlgorithmKey", "RSA_ECB_PKCS1Padding");
        assertThrows(Exception.class, () -> StorageCipherFactory.validateExistingAlgorithms(markers));
    }
}
