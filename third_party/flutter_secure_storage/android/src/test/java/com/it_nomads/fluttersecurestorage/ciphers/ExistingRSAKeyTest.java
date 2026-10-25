package com.it_nomads.fluttersecurestorage.ciphers;

import android.content.Context;

import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.io.InputStream;
import java.io.OutputStream;
import java.security.Key;
import java.security.KeyPair;
import java.security.KeyPairGeneratorSpi;
import java.security.KeyStoreSpi;
import java.security.PrivateKey;
import java.security.Provider;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.Security;
import java.security.UnrecoverableKeyException;
import java.security.cert.Certificate;
import java.security.spec.AlgorithmParameterSpec;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import javax.crypto.spec.SecretKeySpec;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertThrows;

/** AndroidKeyStore read spy, not a claim about a device's Keystore provider. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class ExistingRSAKeyTest {
    private static Key storedKey;
    private static Certificate storedCertificate;
    private static boolean invalidated;
    private static final List<String> aliasesRead = new ArrayList<>();
    private Provider provider;
    private Context context;
    private FlutterSecureStorageConfig config;

    public static class ReadOnlyKeyStore extends KeyStoreSpi {
        @Override public Key engineGetKey(String alias, char[] password) throws UnrecoverableKeyException {
            aliasesRead.add(alias);
            if (invalidated) throw new UnrecoverableKeyException("synthetic invalidation");
            return storedKey;
        }
        @Override public Certificate engineGetCertificate(String alias) {
            aliasesRead.add(alias);
            return storedCertificate;
        }
        @Override public Certificate[] engineGetCertificateChain(String alias) { return null; }
        @Override public Date engineGetCreationDate(String alias) { return null; }
        @Override public void engineSetKeyEntry(String alias, Key key, char[] password, Certificate[] chain) {
            throw new AssertionError("Keystore key writes are forbidden");
        }
        @Override public void engineSetKeyEntry(String alias, byte[] key, Certificate[] chain) {
            throw new AssertionError("Keystore key writes are forbidden");
        }
        @Override public void engineSetCertificateEntry(String alias, Certificate certificate) {
            throw new AssertionError("Keystore certificate writes are forbidden");
        }
        @Override public void engineDeleteEntry(String alias) { throw new AssertionError("Keystore deletion is forbidden"); }
        @Override public Enumeration<String> engineAliases() { return Collections.emptyEnumeration(); }
        @Override public boolean engineContainsAlias(String alias) { return storedKey != null; }
        @Override public int engineSize() { return storedKey == null ? 0 : 1; }
        @Override public boolean engineIsKeyEntry(String alias) { return storedKey != null; }
        @Override public boolean engineIsCertificateEntry(String alias) { return storedCertificate != null; }
        @Override public String engineGetCertificateAlias(Certificate certificate) { return null; }
        @Override public void engineStore(OutputStream stream, char[] password) {
            throw new AssertionError("Keystore store is forbidden");
        }
        @Override public void engineLoad(InputStream stream, char[] password) {}
    }

    public static class ForbiddenGenerator extends KeyPairGeneratorSpi {
        @Override public void initialize(int size, SecureRandom random) { throw new AssertionError("Key generation is forbidden"); }
        @Override public void initialize(AlgorithmParameterSpec spec, SecureRandom random) { throw new AssertionError("Key generation is forbidden"); }
        @Override public KeyPair generateKeyPair() { throw new AssertionError("Key generation is forbidden"); }
    }

    private static class SyntheticPrivateKey implements PrivateKey {
        @Override public String getAlgorithm() { return "RSA"; }
        @Override public String getFormat() { return "PKCS#8"; }
        @Override public byte[] getEncoded() { return new byte[0]; }
    }

    private static class SyntheticPublicKey implements PublicKey {
        @Override public String getAlgorithm() { return "RSA"; }
        @Override public String getFormat() { return "X.509"; }
        @Override public byte[] getEncoded() { return new byte[0]; }
    }

    private static class SyntheticCertificate extends Certificate {
        SyntheticCertificate() { super("X.509"); }
        @Override public byte[] getEncoded() { return new byte[0]; }
        @Override public void verify(PublicKey key) {}
        @Override public void verify(PublicKey key, String provider) {}
        @Override public String toString() { return "synthetic certificate"; }
        @Override public PublicKey getPublicKey() { return new SyntheticPublicKey(); }
    }

    @Before
    public void setUp() {
        assertNull(Security.getProvider("AndroidKeyStore"));
        provider = new Provider("AndroidKeyStore", "1.0", "Synthetic read-only test provider") {};
        provider.put("KeyStore.AndroidKeyStore", ReadOnlyKeyStore.class.getName());
        provider.put("KeyPairGenerator.RSA", ForbiddenGenerator.class.getName());
        Security.addProvider(provider);
        context = RuntimeEnvironment.getApplication();
        Map<String, Object> options = new HashMap<>();
        options.put("storageNamespace", "existing-rsa-test");
        config = new FlutterSecureStorageConfig(options);
        storedKey = new SyntheticPrivateKey();
        storedCertificate = new SyntheticCertificate();
        invalidated = false;
        aliasesRead.clear();
    }

    @After
    public void tearDown() {
        if (Security.getProvider("AndroidKeyStore") == provider) {
            Security.removeProvider("AndroidKeyStore");
        }
    }

    private KeyCipher existing() throws Exception {
        return new KeyCipherImplementationRSAOAEP(context, config, true);
    }

    @Test
    public void readsOnlyExactNormalOaepNamespaceAndDisallowsWrapAndDelete() throws Exception {
        Key before = storedKey;
        KeyCipher reader = existing();
        String alias = context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP.existing-rsa-test";
        assertEquals(List.of(alias, alias), aliasesRead);
        assertThrows(Exception.class, reader::deleteKey);
        assertThrows(Exception.class, () -> reader.wrap(new SecretKeySpec(new byte[16], "AES")));
        assertSame(before, storedKey);
    }

    @Test
    public void missingWrongTypeAndCertificateLessKeysAreNeverCreatedOrReplaced() {
        storedKey = null;
        assertThrows(Exception.class, this::existing);
        assertNull(storedKey);
        storedKey = new SecretKeySpec(new byte[16], "AES");
        Key wrongType = storedKey;
        assertThrows(Exception.class, this::existing);
        assertSame(wrongType, storedKey);
        storedKey = new SyntheticPrivateKey();
        storedCertificate = null;
        assertThrows(Exception.class, this::existing);
        assertNull(storedCertificate);
    }

    @Test
    public void invalidatedKeysFailWithoutDeletionOrGeneration() {
        Key before = storedKey;
        invalidated = true;
        assertThrows(Exception.class, this::existing);
        assertSame(before, storedKey);
    }
}
