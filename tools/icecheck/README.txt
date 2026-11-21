ICE_RAW proof kit (dm-default-key / FBE inline crypto in the ICE vs blk-crypto-fallback), run as root on the phone.
  kat.sh <key128hex> <iv_offset_sectors> <tag>   known-answer test on testparti (sda32, must be 4 MB of zeros; zeroed again
                                                 after): dm-default-key via tools/dmkat, 1 MB pattern (pat.bin), counts
                                                 blk_crypto_fallback_bio_prep and qcom_ice_program_key calls
  katcheck.py <key> <iv> pat ct rt               PC side: ciphertext vs AES-256-XTS (tweak = le128 DUN per 4096-byte unit)
  xk.sh write|verify <set>                       211 files each in DE (/data/local/tmp/xk) and CE (/data/media/0/xk) + md5
  xkv.sh <set>...                                cold-read verify (drop_caches) + fallback call count + fsck/vold/fscrypt lines
Used for rb88 (white cable) and rbich38 (broken screen), ICHTHYS-READINESS.md 12.22.
