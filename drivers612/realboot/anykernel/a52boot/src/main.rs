// SPDX-License-Identifier: GPL-2.0
//! a52boot: the boot image repacker of the a52sxq (Galaxy A52s 5G) 6.12 kernel recovery zip.
//!
//! It replaces only OUR parts of the phone's current images and keeps everything that belongs
//! to the installed ROM:
//!   boot         kernel replaced; ramdisk, os_version/os_patch_level, cmdline, every other
//!                header field kept (header v3/v4; a v4 boot signature is dropped: it signed the
//!                old kernel)
//!   vendor_boot  the ROM's vendor ramdisk kept (fragments of an earlier install of ours removed),
//!                our first-stage ramdisk fragment appended (v3: concatenated, v4: own table
//!                entry "a52sxq-k612"), dtb and vendor cmdline replaced, other header fields kept
//!   dtbo         replaced
//! The AVB hash footer of the current image is the template of the new one: same vbmeta blob
//! (salt, properties, release string, flags), only image_size and digest of the hash descriptor
//! change, so the result is what `avbtool add_hash_footer` makes with the ROM's salt and props.
//! Signed footers (algorithm != NONE) are refused. Output = full partition size.
//!
//! No dependencies (sha256, lz4 legacy decoding and cpio reading are here), static binary.
//! Every command prints key=value lines on stdout; errors go to stderr with exit status 1
//! (2 = usage, 3 = a check that answered "no", e.g. origin mismatch).

use std::fs;
use std::io::Write;
use std::process::exit;

// ------------------------------------------------------------------------------ sha256
struct Sha256 {
    h: [u32; 8],
    buf: [u8; 64],
    n: usize,
    total: u64,
}

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

impl Sha256 {
    fn new() -> Self {
        Sha256 {
            h: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            buf: [0; 64],
            n: 0,
            total: 0,
        }
    }

    fn block(h: &mut [u32; 8], b: &[u8]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([b[4 * i], b[4 * i + 1], b[4 * i + 2], b[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let (mut a, mut b_, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b_) ^ (a & c) ^ (b_ & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b_;
            b_ = a;
            a = t1.wrapping_add(t2);
        }
        for (x, v) in h.iter_mut().zip([a, b_, c, d, e, f, g, hh]) {
            *x = x.wrapping_add(v);
        }
    }

    fn update(&mut self, mut d: &[u8]) {
        self.total += d.len() as u64;
        if self.n > 0 {
            let k = (64 - self.n).min(d.len());
            self.buf[self.n..self.n + k].copy_from_slice(&d[..k]);
            self.n += k;
            d = &d[k..];
            if self.n == 64 {
                let b = self.buf;
                Self::block(&mut self.h, &b);
                self.n = 0;
            }
        }
        while d.len() >= 64 {
            Self::block(&mut self.h, &d[..64]);
            d = &d[64..];
        }
        if !d.is_empty() {
            self.buf[..d.len()].copy_from_slice(d);
            self.n = d.len();
        }
    }

    fn finish(mut self) -> [u8; 32] {
        let bits = self.total.wrapping_mul(8);
        self.update(&[0x80]);
        while self.n != 56 {
            self.update(&[0]);
        }
        self.update(&bits.to_be_bytes());
        let mut out = [0u8; 32];
        for i in 0..8 {
            out[4 * i..4 * i + 4].copy_from_slice(&self.h[i].to_be_bytes());
        }
        out
    }
}

fn sha(d: &[u8]) -> [u8; 32] {
    let mut s = Sha256::new();
    s.update(d);
    s.finish()
}

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{:02x}", b)).collect()
}

fn shahex(d: &[u8]) -> String {
    hex(&sha(d))
}

// ------------------------------------------------------------------------------ helpers
type R<T> = Result<T, String>;

fn rd32(d: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]])
}
fn wr32(d: &mut [u8], o: usize, v: u32) {
    d[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
fn rd64(d: &[u8], o: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&d[o..o + 8]);
    u64::from_le_bytes(b)
}
fn be32(d: &[u8], o: usize) -> u32 {
    u32::from_be_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]])
}
fn be64(d: &[u8], o: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&d[o..o + 8]);
    u64::from_be_bytes(b)
}
fn align(v: usize, a: usize) -> usize {
    v.div_ceil(a) * a
}

fn read(p: &str) -> R<Vec<u8>> {
    fs::read(p).map_err(|e| format!("cannot read {}: {}", p, e))
}

fn write_out(p: &str, d: &[u8]) -> R<()> {
    let tmp = format!("{}.a52tmp", p);
    let mut f = fs::File::create(&tmp).map_err(|e| format!("cannot create {}: {}", tmp, e))?;
    f.write_all(d).map_err(|e| format!("cannot write {}: {}", tmp, e))?;
    f.sync_all().map_err(|e| format!("cannot sync {}: {}", tmp, e))?;
    drop(f);
    fs::rename(&tmp, p).map_err(|e| format!("cannot rename {}: {}", tmp, e))?;
    let back = read(p)?;
    if back != d {
        return Err(format!("{}: read-back differs", p));
    }
    Ok(())
}

fn cstr(d: &[u8]) -> String {
    let n = d.iter().position(|&b| b == 0).unwrap_or(d.len());
    String::from_utf8_lossy(&d[..n]).into_owned()
}

fn find(h: &[u8], n: &[u8]) -> Option<usize> {
    h.windows(n.len()).position(|w| w == n)
}

/// "Linux version X" from an uncompressed kernel Image (empty when compressed/unknown)
fn kernel_version(k: &[u8]) -> String {
    match find(k, b"Linux version ") {
        Some(p) => {
            let s = &k[p + 14..(p + 14 + 128).min(k.len())];
            let e = s.iter().position(|&b| b == b' ' || b == 0).unwrap_or(s.len());
            String::from_utf8_lossy(&s[..e]).into_owned()
        }
        None => String::new(),
    }
}

// ------------------------------------------------------------------------------ lz4 legacy
const LZ4_LEGACY: u32 = 0x184C_2102;
const LZ4_BLOCK_MAX: usize = 8 << 20;

fn lz4_block(src: &[u8], out: &mut Vec<u8>) -> R<()> {
    let start = out.len();
    let mut i = 0;
    let err = || "lz4: corrupt block".to_string();
    loop {
        let tok = *src.get(i).ok_or_else(err)?;
        i += 1;
        let mut lit = (tok >> 4) as usize;
        if lit == 15 {
            loop {
                let b = *src.get(i).ok_or_else(err)?;
                i += 1;
                lit += b as usize;
                if b != 255 {
                    break;
                }
            }
        }
        if i + lit > src.len() {
            return Err(err());
        }
        out.extend_from_slice(&src[i..i + lit]);
        i += lit;
        if i == src.len() {
            break;
        }
        if i + 2 > src.len() {
            return Err(err());
        }
        let off = (src[i] as usize) | ((src[i + 1] as usize) << 8);
        i += 2;
        if off == 0 || off > out.len() - start {
            return Err(err());
        }
        let mut ml = (tok & 15) as usize;
        if ml == 15 {
            loop {
                let b = *src.get(i).ok_or_else(err)?;
                i += 1;
                ml += b as usize;
                if b != 255 {
                    break;
                }
            }
        }
        ml += 4;
        if out.len() - start + ml > LZ4_BLOCK_MAX {
            return Err(err());
        }
        let from = out.len() - off;
        for k in 0..ml {
            let b = out[from + k];
            out.push(b);
        }
    }
    if out.len() - start > LZ4_BLOCK_MAX {
        return Err(err());
    }
    Ok(())
}

/// Parses lz4 legacy streams from offset `at` to the end of `d` (trailing zero bytes allowed).
/// Returns the [begin, end) range of every stream and their decompressed contents.
fn lz4_streams(d: &[u8], at: usize) -> R<Vec<(usize, usize, Vec<u8>)>> {
    let mut v: Vec<(usize, usize, Vec<u8>)> = Vec::new();
    let mut p = at;
    if p + 4 > d.len() || rd32(d, p) != LZ4_LEGACY {
        return Err("lz4: no legacy magic".into());
    }
    let mut begin = p;
    let mut out = Vec::new();
    p += 4;
    loop {
        if p == d.len() || d[p..].iter().all(|&b| b == 0) {
            v.push((begin, p, out));
            return Ok(v);
        }
        if p + 4 > d.len() {
            return Err("lz4: truncated".into());
        }
        let sz = rd32(d, p) as usize;
        if sz as u32 == LZ4_LEGACY {
            v.push((begin, p, std::mem::take(&mut out)));
            begin = p;
            p += 4;
            continue;
        }
        if sz == 0 || sz > LZ4_BLOCK_MAX + LZ4_BLOCK_MAX / 255 + 16 || p + 4 + sz > d.len() {
            return Err("lz4: bad block size".into());
        }
        lz4_block(&d[p + 4..p + 4 + sz], &mut out)?;
        p += 4 + sz;
    }
}

// ------------------------------------------------------------------------------ cpio (newc)
struct CpioEntry {
    name: String,
    data_off: usize,
    size: usize,
}

fn cpio_entries(d: &[u8]) -> R<Vec<CpioEntry>> {
    let mut v = Vec::new();
    let mut p = 0;
    loop {
        // concatenated archives inside one stream: skip the zero padding between them
        while p < d.len() && d[p] == 0 {
            p += 1;
        }
        if p >= d.len() {
            return Ok(v);
        }
        if p + 110 > d.len() || (&d[p..p + 6] != b"070701" && &d[p..p + 6] != b"070702") {
            return Err("cpio: bad header".into());
        }
        let f = |i: usize| -> R<usize> {
            let s = std::str::from_utf8(&d[p + 6 + 8 * i..p + 14 + 8 * i]).map_err(|_| "cpio: bad field")?;
            usize::from_str_radix(s, 16).map_err(|_| "cpio: bad field".to_string())
        };
        let fsize = f(6)?;
        let nsize = f(11)?;
        if nsize == 0 || p + 110 + nsize > d.len() {
            return Err("cpio: bad name".into());
        }
        let name = cstr(&d[p + 110..p + 110 + nsize]);
        let data_off = align(p + 110 + nsize, 4);
        if data_off + fsize > d.len() {
            return Err("cpio: truncated".into());
        }
        p = align(data_off + fsize, 4);
        if name == "TRAILER!!!" {
            continue;
        }
        v.push(CpioEntry { name, data_off, size: fsize });
    }
}

/// true when a decompressed ramdisk fragment is ours (drivers612/realboot first-stage cpio)
fn is_a52_cpio(c: &[u8]) -> bool {
    let Ok(es) = cpio_entries(c) else { return false };
    es.iter().any(|e| {
        let n = e.name.trim_start_matches("./");
        (n == "adb_debug.prop" && find(&c[e.data_off..e.data_off + e.size], b"drivers612/realboot").is_some())
            || n == "lib/modules/a52sxq_dsp_boot.ko"
            || n == "a52sxq-k612.fragment"
    })
}

struct Split {
    rom_len: usize,      // the ROM's part: d[..rom_len]
    a52_streams: usize,  // number of our streams removed
    rom_fstab: i32,      // 1 = a ROM stream has first_stage_ramdisk/fstab.*, 0 = no, -1 = unknown
}

/// Splits a (v3) vendor ramdisk into the ROM's part and our appended lz4 streams.
fn split_ramdisk(d: &[u8]) -> R<Split> {
    // earliest offset from which the rest of the blob is a clean chain of lz4 legacy streams
    let mut chain = None;
    let mut p = 0;
    while p + 4 <= d.len() {
        if rd32(d, p) == LZ4_LEGACY {
            if let Ok(v) = lz4_streams(d, p) {
                chain = Some(v);
                break;
            }
        }
        p += 1;
    }
    let Some(streams) = chain else {
        return Ok(Split { rom_len: d.len(), a52_streams: 0, rom_fstab: -1 });
    };
    let marks: Vec<bool> = streams.iter().map(|s| is_a52_cpio(&s.2)).collect();
    let first = marks.iter().position(|&m| m);
    if let Some(k) = first {
        if marks[k..].iter().any(|&m| !m) {
            return Err("vendor ramdisk: a ROM fragment follows ours (unexpected layout)".into());
        }
    }
    let k = first.unwrap_or(streams.len());
    let rom_len = if k < streams.len() { streams[k].0 } else { d.len() };
    let mut fstab = if p == 0 { 0 } else { -1 };
    for s in &streams[..k] {
        if let Ok(es) = cpio_entries(&s.2) {
            if es.iter().any(|e| e.name.trim_start_matches("./").starts_with("first_stage_ramdisk/fstab.")) {
                fstab = 1;
            }
        }
    }
    Ok(Split { rom_len, a52_streams: streams.len() - k, rom_fstab: fstab })
}

/// validates a fragment file: lz4 legacy, every stream ours
fn check_fragment(f: &[u8]) -> R<()> {
    let v = lz4_streams(f, 0).map_err(|e| format!("fragment: {}", e))?;
    if v.iter().any(|s| !is_a52_cpio(&s.2)) {
        return Err("fragment: not an a52sxq first-stage ramdisk (no marker)".into());
    }
    if v.last().map(|s| s.1) != Some(f.len()) {
        return Err("fragment: trailing bytes".into());
    }
    Ok(())
}

// ------------------------------------------------------------------------------ AVB footer
const AVB_FOOTER: usize = 64;

struct Avb {
    vbmeta: Vec<u8>,
    footer: Vec<u8>,
    orig_size: usize,
    desc_img_size_off: usize, // offsets inside vbmeta
    desc_digest_off: usize,
    salt: Vec<u8>,
    digest: Vec<u8>,
    part: String,
    hash_img_size: usize,
}

fn parse_avb(img: &[u8]) -> R<Option<Avb>> {
    if img.len() < AVB_FOOTER || &img[img.len() - AVB_FOOTER..img.len() - AVB_FOOTER + 4] != b"AVBf" {
        return Ok(None);
    }
    let f = &img[img.len() - AVB_FOOTER..];
    let orig = be64(f, 12) as usize;
    let off = be64(f, 20) as usize;
    let size = be64(f, 28) as usize;
    if off.checked_add(size).is_none_or(|e| e > img.len() - AVB_FOOTER) || size < 256 || orig > off {
        return Err("AVB footer: bad offsets".into());
    }
    let vb = img[off..off + size].to_vec();
    if &vb[0..4] != b"AVB0" {
        return Err("AVB footer: no vbmeta".into());
    }
    let auth = be64(&vb, 12) as usize;
    let aux = be64(&vb, 20) as usize;
    let alg = be32(&vb, 28);
    if alg != 0 || auth != 0 {
        return Err(format!("AVB footer is signed (algorithm {}): not supported", alg));
    }
    let doff = be64(&vb, 96) as usize;
    let dsize = be64(&vb, 104) as usize;
    let a = 256 + auth;
    if a + aux > vb.len() || doff + dsize > aux {
        return Err("AVB vbmeta: bad sizes".into());
    }
    let mut p = a + doff;
    let end = p + dsize;
    let mut hd: Option<(usize, usize, Vec<u8>, Vec<u8>, String, usize)> = None;
    while p + 16 <= end {
        let tag = be64(&vb, p);
        let nb = be64(&vb, p + 8) as usize;
        if p + 16 + nb > end {
            return Err("AVB vbmeta: bad descriptor".into());
        }
        if tag == 2 {
            if hd.is_some() {
                return Err("AVB vbmeta: more than one hash descriptor".into());
            }
            let q = p + 16;
            let isz = be64(&vb, q) as usize;
            let alg = cstr(&vb[q + 8..q + 40]);
            let nl = be32(&vb, q + 40) as usize;
            let sl = be32(&vb, q + 44) as usize;
            let dl = be32(&vb, q + 48) as usize;
            let s = q + 116;
            if alg != "sha256" || dl != 32 || s + nl + sl + dl > p + 16 + nb {
                return Err(format!("AVB hash descriptor: unsupported ({} digest {})", alg, dl));
            }
            let part = String::from_utf8_lossy(&vb[s..s + nl]).into_owned();
            hd = Some((q, s + nl + sl, vb[s + nl..s + nl + sl].to_vec(), vb[s + nl + sl..s + nl + sl + dl].to_vec(), part, isz));
        }
        p += 16 + nb;
    }
    let Some((q, dg, salt, digest, part, isz)) = hd else {
        return Err("AVB vbmeta: no hash descriptor".into());
    };
    Ok(Some(Avb {
        vbmeta: vb,
        footer: f.to_vec(),
        orig_size: orig,
        desc_img_size_off: q,
        desc_digest_off: dg,
        salt,
        digest,
        part,
        hash_img_size: isz,
    }))
}

fn avb_digest(salt: &[u8], content: &[u8]) -> [u8; 32] {
    let mut s = Sha256::new();
    s.update(salt);
    s.update(content);
    s.finish()
}

/// full partition image: content + (template's vbmeta with the new hash) + footer
fn finish_image(content: &[u8], tmpl: &Option<Avb>, total: usize, part: &str) -> R<Vec<u8>> {
    let mut out = content.to_vec();
    match tmpl {
        None => {
            if out.len() > total {
                return Err(format!("{}: {} bytes do not fit the {} byte partition", part, out.len(), total));
            }
            out.resize(total, 0);
        }
        Some(a) => {
            if a.part != part {
                return Err(format!("AVB footer belongs to partition '{}', not '{}'", a.part, part));
            }
            let mut vb = a.vbmeta.clone();
            vb[a.desc_img_size_off..a.desc_img_size_off + 8].copy_from_slice(&(content.len() as u64).to_be_bytes());
            vb[a.desc_digest_off..a.desc_digest_off + 32].copy_from_slice(&avb_digest(&a.salt, content));
            let voff = align(out.len(), 4096);
            if voff + align(vb.len(), 4096) + 4096 > total {
                return Err(format!("{}: {} bytes + AVB footer do not fit the {} byte partition", part, content.len(), total));
            }
            out.resize(voff, 0);
            out.extend_from_slice(&vb);
            out.resize(total - AVB_FOOTER, 0);
            let mut f = a.footer.clone();
            f[12..20].copy_from_slice(&(content.len() as u64).to_be_bytes());
            f[20..28].copy_from_slice(&(voff as u64).to_be_bytes());
            f[28..36].copy_from_slice(&(vb.len() as u64).to_be_bytes());
            out.extend_from_slice(&f);
        }
    }
    Ok(out)
}

fn avb_lines(img: &[u8], content_len: usize) -> R<Vec<String>> {
    let mut v = Vec::new();
    match parse_avb(img)? {
        None => v.push("avb=none".into()),
        Some(a) => {
            v.push("avb=unsigned".into());
            v.push(format!("avb_partition={}", a.part));
            v.push(format!("avb_salt={}", hex(&a.salt)));
            v.push(format!("avb_image_size={}", a.hash_img_size));
            let ok = a.hash_img_size == a.orig_size
                && a.hash_img_size <= img.len()
                && avb_digest(&a.salt, &img[..a.hash_img_size]).as_slice() == a.digest.as_slice();
            v.push(format!("avb_hash_ok={}", ok as u8));
            v.push(format!("avb_covers_content={}", (a.hash_img_size == content_len) as u8));
        }
    }
    Ok(v)
}

// ------------------------------------------------------------------------------ boot (v3/v4)
const PAGE: usize = 4096;

struct Boot {
    hv: u32,
    kernel: (usize, usize),
    ramdisk: (usize, usize),
    sig: (usize, usize),
    end: usize,
}

fn parse_boot(d: &[u8]) -> R<Boot> {
    if d.len() < PAGE || &d[0..8] != b"ANDROID!" {
        return Err("not an Android boot image (no ANDROID! magic)".into());
    }
    let hv = rd32(d, 40);
    if hv != 3 && hv != 4 {
        return Err(format!("boot image header version {} is not supported (only 3 and 4)", hv));
    }
    let ks = rd32(d, 8) as usize;
    let rs = rd32(d, 12) as usize;
    let ss = if hv == 4 { rd32(d, 1580) as usize } else { 0 };
    let k = PAGE;
    let r = k + align(ks, PAGE);
    let s = r + align(rs, PAGE);
    let end = s + align(ss, PAGE);
    if end > d.len() {
        return Err("boot image is truncated".into());
    }
    Ok(Boot { hv, kernel: (k, ks), ramdisk: (r, rs), sig: (s, ss), end })
}

fn os_fields(v: u32) -> (String, String) {
    let osv = v >> 11;
    let lvl = v & 0x7ff;
    (
        format!("{}.{}.{}", (osv >> 14) & 0x7f, (osv >> 7) & 0x7f, osv & 0x7f),
        format!("{:04}-{:02}", (lvl >> 4) + 2000, lvl & 0xf),
    )
}

fn boot_content(cur: &[u8], kernel: &[u8]) -> R<Vec<u8>> {
    let b = parse_boot(cur)?;
    let mut hdr = cur[0..PAGE].to_vec();
    wr32(&mut hdr, 8, kernel.len() as u32);
    if b.hv == 4 {
        wr32(&mut hdr, 1580, 0);
    }
    let mut out = hdr;
    out.extend_from_slice(kernel);
    out.resize(align(out.len(), PAGE), 0);
    out.extend_from_slice(&cur[b.ramdisk.0..b.ramdisk.0 + b.ramdisk.1]);
    out.resize(align(out.len(), PAGE), 0);
    Ok(out)
}

fn check_kernel(k: &[u8]) -> R<()> {
    if k.len() < 64 || &k[56..60] != b"ARMd" {
        return Err("kernel: not an arm64 Image (no ARMd magic)".into());
    }
    Ok(())
}

// ------------------------------------------------------------------------------ vendor_boot (v3/v4)
const VB_NAME: &[u8] = b"a52sxq-k612";

struct Vendor {
    hv: u32,
    page: usize,
    hsize: usize,
    ramdisk: (usize, usize),
    dtb: (usize, usize),
    table: (usize, usize), // v4
    entries: usize,
    entry_size: usize,
    bootconfig: (usize, usize),
    end: usize,
}

fn parse_vendor(d: &[u8]) -> R<Vendor> {
    if d.len() < 2112 || &d[0..8] != b"VNDRBOOT" {
        return Err("not a vendor_boot image (no VNDRBOOT magic)".into());
    }
    let hv = rd32(d, 8);
    if hv != 3 && hv != 4 {
        return Err(format!("vendor_boot header version {} is not supported (only 3 and 4)", hv));
    }
    let page = rd32(d, 12) as usize;
    if page == 0 || page % 2048 != 0 || page > 65536 {
        return Err(format!("vendor_boot: odd page size {}", page));
    }
    let hsize = rd32(d, 2096) as usize;
    let rs = rd32(d, 24) as usize;
    let ds = rd32(d, 2100) as usize;
    let (ts, en, es, bs) = if hv == 4 {
        (rd32(d, 2112) as usize, rd32(d, 2116) as usize, rd32(d, 2120) as usize, rd32(d, 2124) as usize)
    } else {
        (0, 0, 0, 0)
    };
    let r = align(hsize, page);
    let dt = r + align(rs, page);
    let t = dt + align(ds, page);
    let bc = t + align(ts, page);
    let end = bc + align(bs, page);
    if end > d.len() || (hv == 4 && (es < 108 || en * es != ts)) {
        return Err("vendor_boot image is truncated or inconsistent".into());
    }
    Ok(Vendor {
        hv,
        page,
        hsize,
        ramdisk: (r, rs),
        dtb: (dt, ds),
        table: (t, ts),
        entries: en,
        entry_size: es,
        bootconfig: (bc, bs),
        end,
    })
}

/// the ROM's vendor ramdisk without our fragments: v3 = prefix, v4 = entries not named ours
fn vendor_rom_ramdisk(d: &[u8], v: &Vendor) -> R<(Vec<u8>, usize, i32)> {
    let rd = &d[v.ramdisk.0..v.ramdisk.0 + v.ramdisk.1];
    if v.hv == 3 {
        let s = split_ramdisk(rd)?;
        return Ok((rd[..s.rom_len].to_vec(), s.a52_streams, s.rom_fstab));
    }
    let mut keep = Vec::new();
    let mut n = 0;
    for i in 0..v.entries {
        let e = v.table.0 + i * v.entry_size;
        let (sz, off) = (rd32(d, e) as usize, rd32(d, e + 4) as usize);
        if off + sz > rd.len() {
            return Err("vendor_boot v4: bad ramdisk table entry".into());
        }
        let ours = cstr(&d[e + 12..e + 44]).as_bytes() == VB_NAME;
        if ours {
            n += 1;
        } else {
            keep.extend_from_slice(&rd[off..off + sz]);
        }
    }
    Ok((keep, n, -1))
}

fn read_cmdline(p: &str) -> R<Vec<u8>> {
    let mut c = read(p)?;
    while c.last() == Some(&b'\n') || c.last() == Some(&b'\r') {
        c.pop();
    }
    if c.is_empty() || c.len() > 2047 || c.contains(&0) || c.contains(&b'\n') {
        return Err("cmdline file: must be one line of 1..2047 bytes".into());
    }
    Ok(c)
}

fn check_dtb(t: &[u8]) -> R<()> {
    if t.len() < 40 || be32(t, 0) != 0xd00d_feed || be32(t, 4) as usize != t.len() {
        return Err("dtb: not a single flattened device tree".into());
    }
    Ok(())
}

fn vendor_content(cur: &[u8], dtb: &[u8], cmd: &[u8], frag: &[u8]) -> R<(Vec<u8>, usize)> {
    let v = parse_vendor(cur)?;
    let pad = |o: &mut Vec<u8>| o.resize(align(o.len(), v.page), 0);
    let mut hdr = cur[0..v.hsize].to_vec();
    for b in &mut hdr[28..28 + 2048] {
        *b = 0;
    }
    hdr[28..28 + cmd.len()].copy_from_slice(cmd);
    wr32(&mut hdr, 2100, dtb.len() as u32);
    let removed;
    let mut out;
    if v.hv == 3 {
        let (rom, n, _) = vendor_rom_ramdisk(cur, &v)?;
        removed = n;
        wr32(&mut hdr, 24, (rom.len() + frag.len()) as u32);
        out = hdr;
        pad(&mut out);
        out.extend_from_slice(&rom);
        out.extend_from_slice(frag);
        pad(&mut out);
        out.extend_from_slice(dtb);
        pad(&mut out);
    } else {
        let rd = &cur[v.ramdisk.0..v.ramdisk.0 + v.ramdisk.1];
        let mut ramdisk = Vec::new();
        let mut table = Vec::new();
        let mut n = 0;
        for i in 0..v.entries {
            let e = v.table.0 + i * v.entry_size;
            let (sz, off) = (rd32(cur, e) as usize, rd32(cur, e + 4) as usize);
            if off + sz > rd.len() {
                return Err("vendor_boot v4: bad ramdisk table entry".into());
            }
            if cstr(&cur[e + 12..e + 44]).as_bytes() == VB_NAME {
                n += 1;
                continue;
            }
            let mut ent = cur[e..e + v.entry_size].to_vec();
            wr32(&mut ent, 4, ramdisk.len() as u32);
            ramdisk.extend_from_slice(&rd[off..off + sz]);
            table.extend_from_slice(&ent);
        }
        removed = n;
        let mut ent = vec![0u8; v.entry_size];
        wr32(&mut ent, 0, frag.len() as u32);
        wr32(&mut ent, 4, ramdisk.len() as u32);
        wr32(&mut ent, 8, 1); // VENDOR_RAMDISK_TYPE_PLATFORM
        ent[12..12 + VB_NAME.len()].copy_from_slice(VB_NAME);
        ramdisk.extend_from_slice(frag);
        table.extend_from_slice(&ent);
        let en = table.len() / v.entry_size;
        wr32(&mut hdr, 24, ramdisk.len() as u32);
        wr32(&mut hdr, 2112, table.len() as u32);
        wr32(&mut hdr, 2116, en as u32);
        out = hdr;
        pad(&mut out);
        out.extend_from_slice(&ramdisk);
        pad(&mut out);
        out.extend_from_slice(dtb);
        pad(&mut out);
        out.extend_from_slice(&table);
        pad(&mut out);
        out.extend_from_slice(&cur[v.bootconfig.0..v.bootconfig.0 + v.bootconfig.1]);
        pad(&mut out);
    }
    Ok((out, removed))
}

// ------------------------------------------------------------------------------ dtbo
fn check_dtbo(t: &[u8]) -> R<usize> {
    if t.len() < 32 || be32(t, 0) != 0xd7b7_ab1e {
        return Err("dtbo: no DTBO table magic".into());
    }
    let total = be32(t, 4) as usize;
    if total == 0 || total > t.len() {
        return Err("dtbo: bad total size".into());
    }
    Ok(total)
}

/// raw dtbo content of a partition image: what the AVB footer covers (mkdtboimg pads its
/// output to the page size), else the table's total size
fn dtbo_content(img: &[u8]) -> R<Vec<u8>> {
    let n = check_dtbo(img)?;
    let len = match parse_avb(img)? {
        Some(a) if a.hash_img_size >= n && a.hash_img_size <= align(n, PAGE) => a.hash_img_size,
        Some(_) => return Err("dtbo: AVB image size does not match the DTBO table".into()),
        None => n,
    };
    Ok(img[..len].to_vec())
}

// ------------------------------------------------------------------------------ commands
fn kind(d: &[u8]) -> &'static str {
    if d.len() >= 8 && &d[0..8] == b"ANDROID!" {
        "boot"
    } else if d.len() >= 8 && &d[0..8] == b"VNDRBOOT" {
        "vendor_boot"
    } else if d.len() >= 4 && be32(d, 0) == 0xd7b7_ab1e {
        "dtbo"
    } else if d.len() >= 4 && &d[0..4] == b"AVB0" {
        "vbmeta"
    } else {
        "unknown"
    }
}

fn info(p: &str) -> R<Vec<String>> {
    let d = read(p)?;
    let mut o = vec![format!("type={}", kind(&d)), format!("size={}", d.len()), format!("image_sha256={}", shahex(&d))];
    match kind(&d) {
        "boot" => {
            let b = parse_boot(&d)?;
            let (osv, lvl) = os_fields(rd32(&d, 16));
            let k = &d[b.kernel.0..b.kernel.0 + b.kernel.1];
            let kv = kernel_version(k);
            o.push(format!("header_version={}", b.hv));
            o.push(format!("os_version={}", osv));
            o.push(format!("os_patch_level={}", lvl));
            o.push(format!("cmdline={}", cstr(&d[44..44 + 1536])));
            o.push(format!("kernel_size={}", b.kernel.1));
            o.push(format!("kernel_sha256={}", shahex(k)));
            o.push(format!("kernel_version={}", kv));
            if k.len() >= 64 && &k[56..60] == b"ARMd" {
                o.push(format!("kernel_image_size={}", rd64(k, 16)));
            }
            o.push(format!("ramdisk_size={}", b.ramdisk.1));
            o.push(format!("ramdisk_sha256={}", shahex(&d[b.ramdisk.0..b.ramdisk.0 + b.ramdisk.1])));
            o.push(format!("signature_size={}", b.sig.1));
            o.push(format!("content_size={}", b.end));
            o.push(format!("a52={}", kv.starts_with("6.") as u8));
            o.extend(avb_lines(&d, b.end)?);
        }
        "vendor_boot" => {
            let v = parse_vendor(&d)?;
            let (rom, n, fstab) = vendor_rom_ramdisk(&d, &v)?;
            o.push(format!("header_version={}", v.hv));
            o.push(format!("page_size={}", v.page));
            o.push(format!("name={}", cstr(&d[2080..2096])));
            o.push(format!("cmdline={}", cstr(&d[28..28 + 2048])));
            o.push(format!("ramdisk_size={}", v.ramdisk.1));
            o.push(format!("ramdisk_sha256={}", shahex(&d[v.ramdisk.0..v.ramdisk.0 + v.ramdisk.1])));
            o.push(format!("rom_ramdisk_size={}", rom.len()));
            o.push(format!("rom_ramdisk_sha256={}", shahex(&rom)));
            o.push(format!("rom_fstab={}", fstab));
            o.push(format!("a52_fragments={}", n));
            o.push(format!("dtb_size={}", v.dtb.1));
            o.push(format!("dtb_sha256={}", shahex(&d[v.dtb.0..v.dtb.0 + v.dtb.1])));
            if v.hv == 4 {
                o.push(format!("ramdisk_entries={}", v.entries));
                o.push(format!("bootconfig_size={}", v.bootconfig.1));
            }
            o.push(format!("content_size={}", v.end));
            o.push(format!("a52={}", (n > 0) as u8));
            o.extend(avb_lines(&d, v.end)?);
        }
        "dtbo" => {
            let n = check_dtbo(&d)?;
            o.push(format!("content_size={}", n));
            o.push(format!("content_sha256={}", shahex(&d[..n])));
            o.extend(avb_lines(&d, n)?);
        }
        "vbmeta" => {
            o.push(format!("flags={}", be32(&d, 120)));
            o.push(format!("algorithm={}", be32(&d, 28)));
        }
        _ => {}
    }
    Ok(o)
}

/// boot header fields that must stay the ROM's (everything but kernel_size / signature_size)
fn boot_keep_fields(d: &[u8]) -> R<Vec<u8>> {
    let b = parse_boot(d)?;
    let mut h = d[0..PAGE].to_vec();
    wr32(&mut h, 8, 0);
    if b.hv == 4 {
        wr32(&mut h, 1580, 0);
    }
    Ok(h)
}

/// vendor_boot header fields that must stay the ROM's (all but cmdline and the sizes)
fn vendor_keep_fields(d: &[u8]) -> R<Vec<u8>> {
    let v = parse_vendor(d)?;
    let mut h = d[0..v.hsize].to_vec();
    for b in &mut h[28..28 + 2048] {
        *b = 0;
    }
    wr32(&mut h, 24, 0);
    wr32(&mut h, 2100, 0);
    if v.hv == 4 {
        wr32(&mut h, 2112, 0);
        wr32(&mut h, 2116, 0);
    }
    Ok(h)
}

fn cmd_mkboot(cur_p: &str, k_p: &str, out_p: &str) -> R<Vec<String>> {
    let cur = read(cur_p)?;
    let k = read(k_p)?;
    check_kernel(&k)?;
    let tmpl = parse_avb(&cur)?;
    let content = boot_content(&cur, &k)?;
    let out = finish_image(&content, &tmpl, cur.len(), "boot")?;
    // read back what the bootloader sees
    let nb = parse_boot(&out)?;
    if &out[nb.kernel.0..nb.kernel.0 + nb.kernel.1] != k.as_slice() {
        return Err("read-back: kernel differs".into());
    }
    let ob = parse_boot(&cur)?;
    if out[nb.ramdisk.0..nb.ramdisk.0 + nb.ramdisk.1] != cur[ob.ramdisk.0..ob.ramdisk.0 + ob.ramdisk.1] {
        return Err("read-back: ramdisk differs".into());
    }
    if boot_keep_fields(&out)? != boot_keep_fields(&cur)? {
        return Err("read-back: header fields differ".into());
    }
    if tmpl.is_some() && !avb_lines(&out, nb.end)?.iter().any(|l| l == "avb_hash_ok=1") {
        return Err("read-back: AVB hash does not verify".into());
    }
    write_out(out_p, &out)?;
    Ok(vec![
        format!("in_sha256={}", shahex(&cur)),
        format!("out_sha256={}", shahex(&out)),
        format!("kernel_version={}", kernel_version(&k)),
        format!("ramdisk_kept={}", ob.ramdisk.1),
        format!("dropped_signature={}", ob.sig.1),
        format!("content_size={}", content.len()),
    ])
}

fn cmd_mkvendor(cur_p: &str, dtb_p: &str, cmd_p: &str, frag_p: &str, out_p: &str) -> R<Vec<String>> {
    let cur = read(cur_p)?;
    let dtb = read(dtb_p)?;
    check_dtb(&dtb)?;
    let cmd = read_cmdline(cmd_p)?;
    let frag = read(frag_p)?;
    check_fragment(&frag)?;
    let tmpl = parse_avb(&cur)?;
    let ov = parse_vendor(&cur)?;
    let (rom, _, fstab) = vendor_rom_ramdisk(&cur, &ov)?;
    if rom.is_empty() {
        return Err("the current vendor_boot has no ROM vendor ramdisk (only our fragment): flash the ROM's vendor_boot first".into());
    }
    let (content, removed) = vendor_content(&cur, &dtb, &cmd, &frag)?;
    let out = finish_image(&content, &tmpl, cur.len(), "vendor_boot")?;
    let nv = parse_vendor(&out)?;
    if out[nv.dtb.0..nv.dtb.0 + nv.dtb.1] != dtb[..] || cstr(&out[28..28 + 2048]).as_bytes() != cmd.as_slice() {
        return Err("read-back: dtb/cmdline differ".into());
    }
    let (rom2, n2, _) = vendor_rom_ramdisk(&out, &nv)?;
    if rom2 != rom || n2 < 1 {
        return Err("read-back: ROM vendor ramdisk differs".into());
    }
    if nv.hv == 3 {
        let rd = &out[nv.ramdisk.0..nv.ramdisk.0 + nv.ramdisk.1];
        if rd[..rom.len()] != rom[..] || rd[rom.len()..] != frag[..] {
            return Err("read-back: vendor ramdisk differs".into());
        }
    }
    if vendor_keep_fields(&out)? != vendor_keep_fields(&cur)? {
        return Err("read-back: header fields differ".into());
    }
    if tmpl.is_some() && !avb_lines(&out, nv.end)?.iter().any(|l| l == "avb_hash_ok=1") {
        return Err("read-back: AVB hash does not verify".into());
    }
    write_out(out_p, &out)?;
    Ok(vec![
        format!("in_sha256={}", shahex(&cur)),
        format!("out_sha256={}", shahex(&out)),
        format!("rom_ramdisk_size={}", rom.len()),
        format!("rom_ramdisk_sha256={}", shahex(&rom)),
        format!("rom_fstab={}", fstab),
        format!("removed_a52_fragments={}", removed),
        format!("old_cmdline={}", cstr(&cur[28..28 + 2048])),
        format!("vendor_ramdisk_size={}", nv.ramdisk.1),
        format!("content_size={}", content.len()),
    ])
}

fn cmd_mkdtbo(cur_p: &str, raw_p: &str, out_p: &str) -> R<Vec<String>> {
    let cur = read(cur_p)?;
    let raw = read(raw_p)?;
    let n = check_dtbo(&raw)?;
    if raw.len() > align(n, PAGE) || raw[n..].iter().any(|&b| b != 0) {
        return Err("dtbo: file is longer than its table (pass the raw dtbo, not a partition image)".into());
    }
    let n = raw.len();
    let tmpl = parse_avb(&cur)?;
    let out = finish_image(&raw, &tmpl, cur.len(), "dtbo")?;
    if tmpl.is_some() && !avb_lines(&out, n)?.iter().any(|l| l == "avb_hash_ok=1") {
        return Err("read-back: AVB hash does not verify".into());
    }
    write_out(out_p, &out)?;
    Ok(vec![format!("in_sha256={}", shahex(&cur)), format!("out_sha256={}", shahex(&out))])
}

/// ABL: kernel image_size + both ramdisks must fit its fallback load region (build-realboot.sh)
fn cmd_budget(boot_p: &str, vb_p: &str) -> R<Vec<String>> {
    let b = read(boot_p)?;
    let v = read(vb_p)?;
    let pb = parse_boot(&b)?;
    let pv = parse_vendor(&v)?;
    let k = &b[pb.kernel.0..pb.kernel.0 + pb.kernel.1];
    check_kernel(k)?;
    let isz = rd64(k, 16) as usize;
    let need = isz + align(pb.ramdisk.1 + pv.ramdisk.1, 4096);
    let budget = 0x560_0000 - 0x48_2000;
    let o = vec![format!("need={:#x}", need), format!("budget={:#x}", budget)];
    if need > budget {
        return Err(format!("kernel + ramdisks ({:#x}) exceed the bootloader's load region ({:#x})", need, budget));
    }
    Ok(o)
}

/// restore check: were the current images made from these backup images by this tool / build?
fn cmd_origin(cb: &str, cv: &str, bb: &str, bv: &str) -> R<(bool, Vec<String>)> {
    let (cb, cv, bb, bv) = (read(cb)?, read(cv)?, read(bb)?, read(bv)?);
    let mut why = Vec::new();
    let (pcb, pbb) = (parse_boot(&cb)?, parse_boot(&bb)?);
    if boot_keep_fields(&cb)? != boot_keep_fields(&bb)? {
        why.push("boot header (os version/patch level/cmdline)");
    }
    if cb[pcb.ramdisk.0..pcb.ramdisk.0 + pcb.ramdisk.1] != bb[pbb.ramdisk.0..pbb.ramdisk.0 + pbb.ramdisk.1] {
        why.push("boot ramdisk");
    }
    let (pcv, pbv) = (parse_vendor(&cv)?, parse_vendor(&bv)?);
    if vendor_keep_fields(&cv)? != vendor_keep_fields(&bv)? {
        why.push("vendor_boot header");
    }
    if vendor_rom_ramdisk(&cv, &pcv)?.0 != vendor_rom_ramdisk(&bv, &pbv)?.0 {
        why.push("ROM vendor ramdisk");
    }
    let ok = why.is_empty();
    Ok((ok, vec![format!("origin={}", if ok { "match".to_string() } else { format!("differs: {}", why.join(", ")) })]))
}

/// host side: the parts of a built vendor_boot/boot/dtbo the zip ships
fn cmd_extract(boot_p: &str, vb_p: &str, dtbo_p: &str, dir: &str) -> R<Vec<String>> {
    let b = read(boot_p)?;
    let v = read(vb_p)?;
    let t = read(dtbo_p)?;
    let pb = parse_boot(&b)?;
    let pv = parse_vendor(&v)?;
    if pv.hv != 3 {
        return Err("extract: only v3 vendor_boot".into());
    }
    let rd = &v[pv.ramdisk.0..pv.ramdisk.0 + pv.ramdisk.1];
    let s = split_ramdisk(rd)?;
    if s.a52_streams == 0 {
        return Err("extract: the vendor ramdisk has no a52sxq fragment".into());
    }
    fs::create_dir_all(dir).map_err(|e| format!("{}: {}", dir, e))?;
    let k = &b[pb.kernel.0..pb.kernel.0 + pb.kernel.1];
    check_kernel(k)?;
    write_out(&format!("{}/Image", dir), k)?;
    write_out(&format!("{}/vendor_boot.dtb", dir), &v[pv.dtb.0..pv.dtb.0 + pv.dtb.1])?;
    let mut c = cstr(&v[28..28 + 2048]).into_bytes();
    c.push(b'\n');
    write_out(&format!("{}/vendor-cmdline.txt", dir), &c)?;
    write_out(&format!("{}/vendor-ramdisk-a52.cpio.lz4", dir), &rd[s.rom_len..])?;
    write_out(&format!("{}/dtbo.raw", dir), &dtbo_content(&t)?)?;
    Ok(vec![
        format!("kernel_version={}", kernel_version(k)),
        format!("rom_ramdisk_size={}", s.rom_len),
        format!("fragment_size={}", rd.len() - s.rom_len),
    ])
}

// ------------------------------------------------------------------------------ backup packing
// A partition image without its all-zero 4 KiB blocks (a 96 MiB boot partition holds ~50 MB):
//   "A52PACK1" | total size u64 | sha256 of the full image [32] | n u32 | n x (offset u64, len u64)
//   | the extents' bytes. Little endian. unpack checks size and sha256 before writing.
const PACK_MAGIC: &[u8] = b"A52PACK1";

fn pack(d: &[u8]) -> Vec<u8> {
    let mut ext: Vec<(usize, usize)> = Vec::new();
    let mut o = 0;
    while o < d.len() {
        let e = (o + PAGE).min(d.len());
        if d[o..e].iter().any(|&b| b != 0) {
            match ext.last_mut() {
                Some(l) if l.0 + l.1 == o => l.1 += e - o,
                _ => ext.push((o, e - o)),
            }
        }
        o = e;
    }
    let mut out = PACK_MAGIC.to_vec();
    out.extend_from_slice(&(d.len() as u64).to_le_bytes());
    out.extend_from_slice(&sha(d));
    out.extend_from_slice(&(ext.len() as u32).to_le_bytes());
    for &(a, n) in &ext {
        out.extend_from_slice(&(a as u64).to_le_bytes());
        out.extend_from_slice(&(n as u64).to_le_bytes());
    }
    for &(a, n) in &ext {
        out.extend_from_slice(&d[a..a + n]);
    }
    out
}

fn unpack(p: &[u8]) -> R<Vec<u8>> {
    let bad = || "not a valid a52pack file".to_string();
    if p.len() < 52 || &p[0..8] != PACK_MAGIC {
        return Err(bad());
    }
    let total = rd64(p, 8) as usize;
    let n = rd32(p, 48) as usize;
    if total > (1 << 34) || n > total / PAGE + 1 || 52 + 16 * n > p.len() {
        return Err(bad());
    }
    let mut d = vec![0u8; total];
    let mut q = 52 + 16 * n;
    for i in 0..n {
        let a = rd64(p, 52 + 16 * i) as usize;
        let l = rd64(p, 60 + 16 * i) as usize;
        if a.checked_add(l).is_none_or(|e| e > total) || q + l > p.len() {
            return Err(bad());
        }
        d[a..a + l].copy_from_slice(&p[q..q + l]);
        q += l;
    }
    if q != p.len() || sha(&d)[..] != p[16..48] {
        return Err("a52pack: size or sha256 mismatch (damaged backup)".into());
    }
    Ok(d)
}

fn usage() -> ! {
    eprintln!(
        "a52boot 1.0 (a52sxq 6.12 kernel zip)\n\
         usage:\n  a52boot info <img>\n  a52boot mkboot <current boot> <Image> <out>\n  \
         a52boot mkvendor <current vendor_boot> <dtb> <cmdline file> <ramdisk fragment> <out>\n  \
         a52boot mkdtbo <current dtbo> <raw dtbo> <out>\n  a52boot budget <boot> <vendor_boot>\n  \
         a52boot origin <current boot> <current vendor_boot> <backup boot> <backup vendor_boot>\n  \
         a52boot extract <boot> <vendor_boot> <dtbo> <out dir>\n  a52boot sha256 <file>\n  \
         a52boot pack <image> <out.a52pack>\n  a52boot unpack <in.a52pack> <out image|->"
    );
    exit(2)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 2 {
        usage();
    }
    let n = a.len() - 2;
    let r: R<(bool, Vec<String>)> = match (a[1].as_str(), n) {
        ("info", 1) => info(&a[2]).map(|v| (true, v)),
        ("mkboot", 3) => cmd_mkboot(&a[2], &a[3], &a[4]).map(|v| (true, v)),
        ("mkvendor", 5) => cmd_mkvendor(&a[2], &a[3], &a[4], &a[5], &a[6]).map(|v| (true, v)),
        ("mkdtbo", 3) => cmd_mkdtbo(&a[2], &a[3], &a[4]).map(|v| (true, v)),
        ("budget", 2) => cmd_budget(&a[2], &a[3]).map(|v| (true, v)),
        ("origin", 4) => cmd_origin(&a[2], &a[3], &a[4], &a[5]),
        ("extract", 4) => cmd_extract(&a[2], &a[3], &a[4], &a[5]).map(|v| (true, v)),
        ("sha256", 1) => read(&a[2]).map(|d| (true, vec![shahex(&d)])),
        ("pack", 2) => read(&a[2]).and_then(|d| {
            let p = pack(&d);
            // verify before reporting success: unpacks to the same bytes
            if unpack(&p)? != d {
                return Err("pack: verify failed".into());
            }
            write_out(&a[3], &p)?;
            Ok((true, vec![format!("sha256={}", shahex(&d)), format!("size={}", d.len()), format!("packed_size={}", p.len())]))
        }),
        ("unpack", 2) => read(&a[2]).and_then(|p| {
            let d = unpack(&p)?;
            if a[3] != "-" {
                write_out(&a[3], &d)?;
            }
            Ok((true, vec![format!("sha256={}", shahex(&d)), format!("size={}", d.len())]))
        }),
        _ => usage(),
    };
    match r {
        Ok((ok, lines)) => {
            let mut s = String::new();
            for l in lines {
                s.push_str(&l);
                s.push('\n');
            }
            print!("{}", s);
            exit(if ok { 0 } else { 3 })
        }
        Err(e) => {
            eprintln!("a52boot: {}", e);
            exit(1)
        }
    }
}
