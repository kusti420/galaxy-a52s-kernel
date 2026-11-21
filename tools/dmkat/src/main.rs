// SPDX-License-Identifier: GPL-2.0
//! dmkat: create/remove a device-mapper device with ONE target of any type (dmctl knows no default-key).
//!   dmkat create <name> <start> <len> <target_type> <params...>   -> prints "major:minor"
//!   dmkat remove <name>
use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;

extern "C" {
    fn ioctl(fd: i32, req: u64, ...) -> i32;
}
const HDR: usize = 312;
const SPEC: usize = 40;
fn req(nr: u64) -> u64 { (3u64 << 30) | ((HDR as u64) << 16) | (0xfd << 8) | nr }
const DEV_CREATE: u64 = 3;
const DEV_REMOVE: u64 = 4;
const DEV_SUSPEND: u64 = 6;
const TABLE_LOAD: u64 = 9;

fn hdr(buf: &mut Vec<u8>, name: &str, total: usize, tcount: u32) {
    buf.resize(total, 0);
    for (i, v) in [4u32, 0, 0].iter().enumerate() { buf[i * 4..i * 4 + 4].copy_from_slice(&v.to_ne_bytes()); }
    buf[12..16].copy_from_slice(&(total as u32).to_ne_bytes());
    buf[16..20].copy_from_slice(&(HDR as u32).to_ne_bytes());
    buf[20..24].copy_from_slice(&tcount.to_ne_bytes());
    let n = name.as_bytes();
    assert!(n.len() < 128, "name too long");
    buf[48..48 + n.len()].copy_from_slice(n);
}

fn call(fd: i32, nr: u64, buf: &mut Vec<u8>, what: &str) {
    let r = unsafe { ioctl(fd, req(nr), buf.as_mut_ptr()) };
    if r != 0 {
        eprintln!("dmkat: {} failed: {}", what, std::io::Error::last_os_error());
        std::process::exit(1);
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let ctl = OpenOptions::new().read(true).write(true).open("/dev/device-mapper")
        .or_else(|_| OpenOptions::new().read(true).write(true).open("/dev/mapper/control"))
        .expect("open device-mapper control");
    let fd = ctl.as_raw_fd();
    match a.get(1).map(|s| s.as_str()) {
        Some("create") if a.len() >= 7 => {
            let (name, start, len, ty) = (&a[2], a[3].parse::<u64>().unwrap(), a[4].parse::<u64>().unwrap(), &a[5]);
            let params = a[6..].join(" ");
            let mut b = Vec::new();
            hdr(&mut b, name, HDR, 0);
            call(fd, DEV_CREATE, &mut b, "DM_DEV_CREATE");
            let plen = (params.len() + 1 + 7) & !7;
            let total = HDR + SPEC + plen;
            let mut t = Vec::new();
            hdr(&mut t, name, total, 1);
            let s = HDR;
            t[s..s + 8].copy_from_slice(&start.to_ne_bytes());
            t[s + 8..s + 16].copy_from_slice(&len.to_ne_bytes());
            let tb = ty.as_bytes();
            assert!(tb.len() < 16);
            t[s + 24..s + 24 + tb.len()].copy_from_slice(tb);
            t[s + SPEC..s + SPEC + params.len()].copy_from_slice(params.as_bytes());
            call(fd, TABLE_LOAD, &mut t, "DM_TABLE_LOAD");
            let mut r = Vec::new();
            hdr(&mut r, name, HDR, 0);
            call(fd, DEV_SUSPEND, &mut r, "DM_DEV_SUSPEND (resume)");
            let dev = u64::from_ne_bytes(r[40..48].try_into().unwrap());
            let (maj, min) = ((dev >> 8) & 0xfff, (dev & 0xff) | ((dev >> 12) & 0xfff00));
            println!("{}:{}", maj, min);
        }
        Some("remove") if a.len() == 3 => {
            let mut b = Vec::new();
            hdr(&mut b, &a[2], HDR, 0);
            call(fd, DEV_REMOVE, &mut b, "DM_DEV_REMOVE");
        }
        _ => { eprintln!("usage: dmkat create <name> <start> <len> <type> <params...> | dmkat remove <name>"); std::process::exit(2); }
    }
}
