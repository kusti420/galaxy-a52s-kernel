#!/usr/bin/env python3
"""Print the signing metadata of Qualcomm split firmware (<name>.mdt / <name>.b01 hash segment).

Usage: mbnver.py <file.mdt|file.b01> [...]
Read-only. Prints header version, sw_id and anti_rollback_version of the QTI and OEM metadata
blocks (hash-segment header v6/v7: 48-byte header, then QTI metadata, then OEM metadata).
The OEM block's anti_rollback_version is what Samsung TZ compares against the fused/stored
counter (2026-11-13 incident: phone 2's counter is 5 now).

For an .mdt the hash segment is found from the ELF program headers (the segment whose p_flags
OS-specific bits say "hash", type 2 in bits 24..26); for a .b01 the file is the hash segment.
"""
import struct
import sys

MD_FIELDS = ("major", "minor", "sw_id", "hw_id", "oem_id", "model_id", "app_id", "flags")


def parse_md(buf, off, size):
    if size < 120 or off + 120 > len(buf):
        return None
    v = struct.unpack_from("<8I", buf, off)
    d = dict(zip(MD_FIELDS, v))
    d["root_cert_index"], d["anti_rollback_version"] = struct.unpack_from("<2I", buf, off + 112)
    return d


def hash_segment(data):
    """Return the hash segment bytes of an .mdt (ELF32 or ELF64), or None."""
    if data[:4] != b"\x7fELF":
        return None
    is64 = data[4] == 2
    if is64:
        phoff, = struct.unpack_from("<Q", data, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    else:
        phoff, = struct.unpack_from("<I", data, 0x1c)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x2a)
    first_filesz = None
    for i in range(phnum):
        o = phoff + i * phentsize
        if is64:
            p_type, p_flags, p_offset, _, _, p_filesz = struct.unpack_from("<IIQQQQ", data, o)
        else:
            p_type, p_offset, _, _, p_filesz, _, p_flags = struct.unpack_from("<IIIIIII", data, o)
        if first_filesz is None:
            first_filesz = p_filesz
        if (p_flags >> 24) & 7 == 2:  # QCOM_MDT_TYPE_HASH
            # as qcom_mdt_read_metadata(): in a split .mdt the hash segment follows the ELF
            # header segment (offset = phdr[0].p_filesz), not at p_offset
            if first_filesz + p_filesz <= len(data):
                return data[first_filesz:first_filesz + p_filesz]
            if p_offset + p_filesz <= len(data):
                return data[p_offset:p_offset + p_filesz]
            return None
    return None


def main():
    for path in sys.argv[1:]:
        data = open(path, "rb").read()
        seg = hash_segment(data) if path.endswith(".mdt") else data
        if seg is None:
            # split images keep the hash segment in .b01 only; the .mdt carries it too normally
            print(f"{path}: no hash segment found")
            continue
        img_id, ver, qti_sig, qti_chain, img_size, code_size, sig_ptr, sig_size, chain_ptr, \
            chain_size = struct.unpack_from("<10I", seg, 0)
        if ver not in (6, 7):
            print(f"{path}: hash segment header version {ver} (not 6/7): field layout unknown")
            continue
        qti_md, oem_md = struct.unpack_from("<2I", seg, 40)
        qti = parse_md(seg, 48, qti_md)
        oem = parse_md(seg, 48 + qti_md, oem_md)
        out = [f"{path}: hdr v{ver} qti_md={qti_md} oem_md={oem_md}"]
        if qti:
            out.append(f"QTI sw_id={qti['sw_id']:#x} rollback={qti['anti_rollback_version']}")
        if oem:
            out.append(f"OEM sw_id={oem['sw_id']:#x} oem_id={oem['oem_id']:#x} "
                       f"rollback={oem['anti_rollback_version']}")
        print("  ".join(out))


if __name__ == "__main__":
    main()
