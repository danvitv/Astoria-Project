package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.util.Base64;

import com.it_nomads.fluttersecurestorage.ciphers.StorageCipher;
import com.it_nomads.fluttersecurestorage.ciphers.StorageCipherFactory;

import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.HashMap;
import java.util.Map;

/** A per-call reader: never initializes, reads, or publishes an ordinary storage cache. */
final class ExistingStorageReader {
    @FunctionalInterface
    interface CipherLoader {
        StorageCipher load(Context context, Map<String, ?> markers,
                           FlutterSecureStorageConfig config, Map<String, ?> keyEntries) throws Exception;
    }

    private final Context context;
    private final CipherLoader cipherLoader;

    ExistingStorageReader(Context context) {
        this(context, StorageCipherFactory::getExistingStorageCipher);
    }

    // Synthetic tests can replace cryptography, not backend validation or routing.
    ExistingStorageReader(Context context, CipherLoader cipherLoader) {
        this.context = context;
        this.cipherLoader = cipherLoader;
    }

    String read(Object payload) throws Exception {
        if (context == null || !(payload instanceof Map<?, ?>)) {
            throw unavailable();
        }
        Map<?, ?> args = (Map<?, ?>) payload;
        Object rawKey = args.get("key");
        Object rawOptions = args.get("options");
        if (!(rawKey instanceof String) || !(rawOptions instanceof Map<?, ?>)) {
            throw unavailable();
        }
        Map<String, Object> options = new HashMap<>();
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) rawOptions).entrySet()) {
            if (!(entry.getKey() instanceof String) || !(entry.getValue() instanceof String)) {
                throw unavailable();
            }
            options.put((String) entry.getKey(), entry.getValue());
        }
        validateBoolean(options, FlutterSecureStorageConfig.PREF_OPTION_ENCRYPTED_SHARED_PREFERENCES);
        validateBoolean(options, FlutterSecureStorageConfig.PREF_OPTION_ENFORCE_BIOMETRICS);
        if ("true".equals(options.get(FlutterSecureStorageConfig.PREF_OPTION_ENCRYPTED_SHARED_PREFERENCES))
                || "true".equals(options.get(FlutterSecureStorageConfig.PREF_OPTION_ENFORCE_BIOMETRICS))) {
            throw unavailable();
        }
        FlutterSecureStorageConfig config = new FlutterSecureStorageConfig(options, false);
        // Never open Android SharedPreferences: it caches values, silently treats
        // corrupt XML as empty, and can rename a .bak file during a mere read.
        try (ExistingPreferencesSnapshot data = ExistingPreferencesSnapshot.open(context, config.getEffectiveDataPrefsName());
             ExistingPreferencesSnapshot keys = ExistingPreferencesSnapshot.open(context, config.getEffectiveKeyStoragePrefsName());
             ExistingPreferencesSnapshot algorithms = ExistingPreferencesSnapshot.open(context,
                     "FlutterSecureStorageConfiguration:" + config.getEffectiveDataPrefsName())) {
            // Keep all original descriptors until after key loading/decryption.
            Map<String, ?> dataEntries = data.values();
            Map<String, ?> keyEntries = keys.values();
            Map<String, ?> markers = algorithms.values();
            StorageCipherFactory.validateExistingAlgorithms(markers);
            denyMigrationArtifacts(markers);
            denyMigrationArtifacts(dataEntries);
            denyMigrationArtifacts(keyEntries);
            // ESP's Tink keysets live in the plain data prefs. Never open ESP or Tink.
            for (String name : dataEntries.keySet()) {
                if (name.startsWith("__androidx_security_crypto_encrypted_prefs_")) {
                    throw unavailable();
                }
            }
            StorageCipher cipher = cipherLoader.load(context, markers, config, keyEntries);
            String storedKey = config.getSharedPreferencesKeyPrefix() + "_" + (String) rawKey;
            String value = null;
            if (dataEntries.containsKey(storedKey)) {
                Object rawValue = dataEntries.get(storedKey);
                if (!(rawValue instanceof String)) throw unavailable();
                byte[] encrypted = Base64.decode((String) rawValue, Base64.DEFAULT);
                // 12-byte IV + 16-byte authentication tag, including a valid empty value.
                if (encrypted.length < 28) throw unavailable();
                byte[] plaintext = cipher.decrypt(encrypted);
                value = StandardCharsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                        .decode(ByteBuffer.wrap(plaintext)).toString();
            }
            data.verifyUnchanged();
            keys.verifyUnchanged();
            algorithms.verifyUnchanged();
            return value;
        }
    }

    private static void validateBoolean(Map<String, Object> options, String name) throws GeneralSecurityException {
        Object value = options.get(name);
        if (value != null && !"true".equals(value) && !"false".equals(value)) {
            throw unavailable();
        }
    }

    private static void denyMigrationArtifacts(Map<String, ?> entries) throws GeneralSecurityException {
        for (String name : entries.keySet()) {
            if ("FlutterSecureStorageBackupStatus".equals(name)
                    || name.endsWith("_BACKUP") || name.endsWith("_MIGRATED")) {
                throw unavailable();
            }
        }
    }

    private static GeneralSecurityException unavailable() {
        return new GeneralSecurityException("Existing secure storage is unavailable.");
    }
}
