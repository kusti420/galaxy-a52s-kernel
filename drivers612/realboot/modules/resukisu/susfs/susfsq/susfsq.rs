// SPDX-License-Identifier: GPL-2.0
// susfsq: asks the kernel's SUSFS for version, variant and enabled features, the way `ksud susfs show ...` does:
// reboot(KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_*, &struct) as root. Static, no crates: for the QEMU smoke
// test (qemu-susfs-test.sh) and for a first look on a phone before ksud is installed. Read-only.
use std::arch::asm;

const KSU_INSTALL_MAGIC1: u64 = 0xDEADBEEF;
const SUSFS_MAGIC: u64 = 0xFAFAFAFA;
const CMD_SHOW_VERSION: u64 = 0x555e1;
const CMD_SHOW_ENABLED_FEATURES: u64 = 0x555e2;
const CMD_SHOW_VARIANT: u64 = 0x555e3;
const ERR_UNSET: i32 = 0x7fff_fffe;

#[repr(C)]
struct Small {
    s: [u8; 16],
    err: i32,
}

#[repr(C)]
struct Features {
    s: [u8; 8192],
    err: i32,
}

fn call(cmd: u64, arg: *mut u8) -> i64 {
    let r: i64;
    unsafe {
        asm!("svc 0", in("x8") 142u64, inlateout("x0") KSU_INSTALL_MAGIC1 => r, in("x1") SUSFS_MAGIC,
             in("x2") cmd, in("x3") arg);
    }
    r
}

fn text(b: &[u8]) -> String {
    let n = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..n]).into_owned()
}

fn main() {
    let mut rc = 0;
    for (name, cmd) in [("version", CMD_SHOW_VERSION), ("variant", CMD_SHOW_VARIANT)] {
        let mut v = Small { s: [0; 16], err: ERR_UNSET };
        let r = call(cmd, &mut v as *mut Small as *mut u8);
        if v.err == 0 {
            println!("susfs {}: {}", name, text(&v.s));
        } else {
            println!("susfs {}: NOT AVAILABLE (syscall {}, err {:#x})", name, r, v.err);
            rc = 1;
        }
    }
    let mut f = Box::new(Features { s: [0; 8192], err: ERR_UNSET });
    let r = call(CMD_SHOW_ENABLED_FEATURES, &mut *f as *mut Features as *mut u8);
    if f.err == 0 {
        println!("susfs features: {}", text(&f.s).split_whitespace().collect::<Vec<_>>().join(" "));
    } else {
        println!("susfs features: NOT AVAILABLE (syscall {}, err {:#x})", r, f.err);
        rc = 1;
    }
    std::process::exit(rc);
}
