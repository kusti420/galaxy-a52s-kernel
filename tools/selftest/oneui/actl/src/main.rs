// actl: ALSA control probe for the OneUI parity sweep (tools/selftest/oneui). No audio is played or recorded.
//   actl list [card]            every control: "CTL <numid> <iface> <type> <count> <access-hex> <name>" (read-only)
//   actl has  [card] < names    one control name per line on stdin: "HAS <y|n> <name>" (read-only)
//   actl get  [card] < names    type, value count and current values of each named control (read-only):
//                               "VAL <type>:<count> <name> = v0 v1 ..." (at most 16 values, bytes in hex), or
//                               "VAL absent <name>"
//   actl encfmt [card]          A2DP offload: which encoder formats "SLIM_7_RX Encoder Config" accepts.
//                               Writes the control with <format, all-zero config> for each format and resets it with
//                               format 0 at the end (what the HAL's reset does). The put only stores the blob in the
//                               back end's private data; nothing is sent to the DSP unless SLIMBUS_7_RX is opened
//                               afterwards. DO NOT run it while a Bluetooth audio stream is up (the check guards it).
//                               Lines: "ENCFMT <name> <0xid> <ok|errno-name>".
use std::io::{BufRead, Error};

extern "C" {
    fn open(path: *const u8, flags: i32, ...) -> i32;
    fn close(fd: i32) -> i32;
    fn ioctl(fd: i32, req: u64, ...) -> i32;
}

const ELEM_LIST: u64 = 0xC050_5510;
const ELEM_INFO: u64 = 0xC110_5511;
const ELEM_READ: u64 = 0xC4C8_5512;
const ELEM_WRITE: u64 = 0xC4C8_5513;

#[repr(C)]
#[derive(Clone, Copy)]
struct ElemId { numid: u32, iface: i32, device: u32, subdevice: u32, name: [u8; 44], index: u32 }
#[repr(C)]
struct ElemList { offset: u32, space: u32, used: u32, count: u32, pids: *mut ElemId, reserved: [u8; 50] }
#[repr(C)]
struct ElemInfo { id: ElemId, typ: i32, access: u32, count: u32, owner: i32, value: [u64; 16], reserved: [u8; 64] }
#[repr(C)]
struct ElemValue { id: ElemId, indirect: u32, pad: u32, data: [u8; 1024], tail: [u8; 128] }

const _: () = assert!(std::mem::size_of::<ElemId>() == 64);
const _: () = assert!(std::mem::size_of::<ElemList>() == 0x50);
const _: () = assert!(std::mem::size_of::<ElemInfo>() == 0x110);
const _: () = assert!(std::mem::size_of::<ElemValue>() == 0x4C8);

fn errno() -> i32 { Error::last_os_error().raw_os_error().unwrap_or(0) }
fn ename(e: i32) -> String {
    match e { 1 => "EPERM".into(), 2 => "ENOENT".into(), 13 => "EACCES".into(), 16 => "EBUSY".into(), 19 => "ENODEV".into(),
        22 => "EINVAL".into(), 25 => "ENOTTY".into(), _ => format!("errno{}", e) }
}
fn cname(id: &ElemId) -> String {
    let n = id.name.iter().position(|&c| c == 0).unwrap_or(44);
    String::from_utf8_lossy(&id.name[..n]).into_owned()
}
fn open_card(card: &str) -> i32 {
    let p = format!("/dev/snd/controlC{}\0", card);
    let fd = unsafe { open(p.as_ptr(), 2 /* O_RDWR */) };
    if fd < 0 { println!("ACTL open {} {}", &p[..p.len() - 1], ename(errno())); std::process::exit(1); }
    fd
}
fn list(fd: i32) -> Vec<ElemId> {
    let mut l = ElemList { offset: 0, space: 0, used: 0, count: 0, pids: std::ptr::null_mut(), reserved: [0; 50] };
    if unsafe { ioctl(fd, ELEM_LIST, &mut l as *mut ElemList) } < 0 { println!("ACTL list {}", ename(errno())); std::process::exit(1); }
    let zero = ElemId { numid: 0, iface: 0, device: 0, subdevice: 0, name: [0; 44], index: 0 };
    let mut ids = vec![zero; l.count as usize];
    l.space = l.count; l.pids = ids.as_mut_ptr();
    if unsafe { ioctl(fd, ELEM_LIST, &mut l as *mut ElemList) } < 0 { println!("ACTL list {}", ename(errno())); std::process::exit(1); }
    ids.truncate(l.used as usize);
    ids
}
fn info(fd: i32, id: &ElemId) -> Option<ElemInfo> {
    let mut i = ElemInfo { id: *id, typ: 0, access: 0, count: 0, owner: 0, value: [0; 16], reserved: [0; 64] };
    if unsafe { ioctl(fd, ELEM_INFO, &mut i as *mut ElemInfo) } < 0 { None } else { Some(i) }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let cmd = a.get(1).map(|s| s.as_str()).unwrap_or("");
    let card = a.get(2).map(|s| s.as_str()).unwrap_or("0");
    const IFACE: [&str; 7] = ["card", "hwdep", "mixer", "pcm", "rawmidi", "timer", "seq"];
    const TYPE: [&str; 7] = ["none", "bool", "int", "enum", "bytes", "iec958", "int64"];
    match cmd {
        "list" => {
            let fd = open_card(card);
            let ids = list(fd);
            println!("ACTL controls {}", ids.len());
            for id in &ids {
                let (t, c, acc) = match info(fd, id) { Some(i) => (i.typ, i.count, i.access), None => (-1, 0, 0) };
                println!("CTL {} {} {} {} {:x} {}", id.numid, IFACE.get(id.iface as usize).unwrap_or(&"?"),
                    if t < 0 { "?" } else { TYPE.get(t as usize).unwrap_or(&"?") }, c, acc, cname(id));
            }
            unsafe { close(fd); }
        }
        "has" => {
            let fd = open_card(card);
            let names: std::collections::HashSet<String> = list(fd).iter().map(cname).collect();
            for l in std::io::stdin().lock().lines().map_while(Result::ok) {
                let n = l.trim(); if n.is_empty() { continue; }
                println!("HAS {} {}", if names.contains(n) { "y" } else { "n" }, n);
            }
            unsafe { close(fd); }
        }
        "get" => {
            let fd = open_card(card);
            let ids = list(fd);
            for l in std::io::stdin().lock().lines().map_while(Result::ok) {
                let n = l.trim(); if n.is_empty() { continue; }
                let Some(id) = ids.iter().find(|i| cname(i) == n) else { println!("VAL absent {}", n); continue; };
                let Some(inf) = info(fd, id) else { println!("VAL noinfo {}", n); continue; };
                let t = TYPE.get(inf.typ as usize).unwrap_or(&"?");
                let mut v = ElemValue { id: *id, indirect: 0, pad: 0, data: [0; 1024], tail: [0; 128] };
                if unsafe { ioctl(fd, ELEM_READ, &mut v as *mut ElemValue) } < 0 { println!("VAL {}:{} {} = {}", t, inf.count, n, ename(errno())); continue; }
                let k = (inf.count as usize).min(16);
                let vals: Vec<String> = (0..k).map(|i| match inf.typ {
                    1 | 2 => i64::from_le_bytes(v.data[i * 8..i * 8 + 8].try_into().unwrap()).to_string(),   // long[]
                    3 => u32::from_le_bytes(v.data[i * 4..i * 4 + 4].try_into().unwrap()).to_string(),       // enum item
                    6 => i64::from_le_bytes(v.data[i * 8..i * 8 + 8].try_into().unwrap()).to_string(),
                    _ => format!("{:02x}", v.data[i]),
                }).collect();
                println!("VAL {}:{} {} = {}", t, inf.count, n, vals.join(" "));
            }
            unsafe { close(fd); }
        }
        "encfmt" => {
            let fd = open_card(card);
            let ids = list(fd);
            let Some(id) = ids.iter().find(|i| cname(i) == "SLIM_7_RX Encoder Config") else {
                println!("ENCFMT control absent"); std::process::exit(2);
            };
            let cnt = info(fd, id).map(|i| i.count).unwrap_or(0);
            println!("ENCFMT control numid={} bytes={}", id.numid, cnt);
            // ASM media format ids (5.4 techpack/audio include/dsp/apr_audio-v2.h); SSC + SBC_SS are Samsung's
            let fmts: [(&str, u32); 8] = [("sbc", 0x0001_0BF2), ("aac", 0x0001_0DA6), ("aptx", 0x0001_31ff),
                ("aptx_hd", 0x0001_3200), ("ldac", 0x0001_3224), ("aptx_adaptive", 0x0001_3204),
                ("ssc", 0x0001_0BF3), ("sbc_ss", 0x0001_0BF5)];
            let put = |f: u32| -> i32 {
                let mut v = ElemValue { id: *id, indirect: 0, pad: 0, data: [0; 1024], tail: [0; 128] };
                v.data[..4].copy_from_slice(&f.to_le_bytes());
                if unsafe { ioctl(fd, ELEM_WRITE, &mut v as *mut ElemValue) } < 0 { errno() } else { 0 }
            };
            for (n, f) in fmts {
                let e = put(f);
                println!("ENCFMT {} {:#x} {}", n, f, if e == 0 { "ok".into() } else { ename(e) });
            }
            // reset: format 0 clears the stored config (the put answers EINVAL for format 0 on every kernel)
            let e = put(0);
            println!("ENCFMT reset 0x0 {}", if e == 0 { "ok".into() } else { ename(e) });
            unsafe { close(fd); }
        }
        _ => { println!("usage: actl list|has|get|encfmt [card]"); std::process::exit(64); }
    }
}
