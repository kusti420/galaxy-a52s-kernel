package org.a52sxq.bench;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyInfo;
import android.security.keystore.KeyProperties;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;

/** crypto.keystore: AndroidKeyStore EC P-256 + AES-256-GCM in the TEE: hardware-backed check, sign/verify, encrypt/decrypt. */
public class CryptoKeystore extends Test {
    public String id() { return "crypto.keystore"; }
    public int budget(Ctx c) { return 60; }
    static final String EC = "a52bench_ec", AES = "a52bench_aes";

    static int level(KeyInfo ki) { try { return ki.getSecurityLevel(); } catch (Throwable t) { return ki.isInsideSecureHardware() ? 1 : 0; } }
    static boolean hw(KeyInfo ki) { try { int l = ki.getSecurityLevel(); return l == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT || l == KeyProperties.SECURITY_LEVEL_STRONGBOX || l == KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE; } catch (Throwable t) { return ki.isInsideSecureHardware(); } }

    public void run(Ctx c, Result r) throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
        try {
            long t0 = System.nanoTime();
            KeyPairGenerator kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            kpg.initialize(new KeyGenParameterSpec.Builder(EC, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1")).setDigests(KeyProperties.DIGEST_SHA256).build());
            KeyPair kp = kpg.generateKeyPair();
            r.num("ec_keygen_ms", (System.nanoTime() - t0) / 1e6);
            KeyInfo eki = KeyFactory.getInstance(kp.getPrivate().getAlgorithm(), "AndroidKeyStore").getKeySpec(kp.getPrivate(), KeyInfo.class);
            r.num("ec_security_level", (long) level(eki)).num("ec_hw_backed", hw(eki) ? 1L : 0L);
            if (!hw(eki)) r.fail("EC key is not hardware-backed (security level " + level(eki) + ")");

            byte[] msg = new byte[1024]; for (int i = 0; i < msg.length; i++) msg[i] = (byte) (i * 31 + 7);
            int n = 0; byte[] sig = null; t0 = System.nanoTime();
            while (n < 20 && System.nanoTime() - t0 < 8e9) { Signature s = Signature.getInstance("SHA256withECDSA"); s.initSign(kp.getPrivate()); s.update(msg); sig = s.sign(); n++; }
            r.num("ec_sign_ops_s", n / ((System.nanoTime() - t0) / 1e9));
            Signature v = Signature.getInstance("SHA256withECDSA"); v.initVerify(kp.getPublic()); v.update(msg);
            boolean ok = v.verify(sig);
            msg[5] ^= 1; v = Signature.getInstance("SHA256withECDSA"); v.initVerify(kp.getPublic()); v.update(msg);
            boolean tamper = v.verify(sig); msg[5] ^= 1;
            r.num("ec_verify_ok", ok ? 1L : 0L).num("ec_tamper_rejected", tamper ? 0L : 1L);
            if (!ok) r.fail("ECDSA signature did not verify");
            if (tamper) r.fail("ECDSA verified a tampered message");

            t0 = System.nanoTime();
            KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            kg.init(new KeyGenParameterSpec.Builder(AES, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT).setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            SecretKey sk = kg.generateKey();
            r.num("aes_keygen_ms", (System.nanoTime() - t0) / 1e6);
            KeyInfo aki = (KeyInfo) SecretKeyFactory.getInstance(sk.getAlgorithm(), "AndroidKeyStore").getKeySpec(sk, KeyInfo.class);
            r.num("aes_security_level", (long) level(aki)).num("aes_hw_backed", hw(aki) ? 1L : 0L);
            if (!hw(aki)) r.fail("AES key is not hardware-backed (security level " + level(aki) + ")");

            byte[] plain = new byte[65536]; for (int i = 0; i < plain.length; i++) plain[i] = (byte) (i * 131 + 3);
            n = 0; long bytes = 0; boolean rt = true; t0 = System.nanoTime();
            while (n < 20 && System.nanoTime() - t0 < 8e9) {
                Cipher e = Cipher.getInstance("AES/GCM/NoPadding"); e.init(Cipher.ENCRYPT_MODE, sk); byte[] ct = e.doFinal(plain); byte[] iv = e.getIV();
                Cipher d = Cipher.getInstance("AES/GCM/NoPadding"); d.init(Cipher.DECRYPT_MODE, sk, new GCMParameterSpec(128, iv));
                byte[] back = d.doFinal(ct);
                if (!Arrays.equals(back, plain) || Arrays.equals(Arrays.copyOf(ct, plain.length), plain)) rt = false;
                n++; bytes += 2L * plain.length;
            }
            double sec = (System.nanoTime() - t0) / 1e9;
            r.num("aes_roundtrips_s", n / sec).num("aes_mb_s", bytes / 1048576.0 / sec).num("aes_roundtrip_ok", rt ? 1L : 0L);
            if (!rt || n == 0) r.fail("AES-GCM round trip mismatch");
            r.pass("EC P-256 + AES-256-GCM hardware-backed (level " + level(eki) + "/" + level(aki) + "), sign/verify and encrypt/decrypt verified");
        } finally {
            try { ks.deleteEntry(EC); } catch (Throwable t) { }
            try { ks.deleteEntry(AES); } catch (Throwable t) { }
        }
    }
}
