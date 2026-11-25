// kq: read-only kernel feature probes for the OneUI parity sweep (tools/selftest/oneui).
// Prints one "KQ <name> <ok|errno-name> [detail]" line per probe; changes nothing on the phone.
// Every probe either calls a syscall with arguments that cannot have an effect (bad fd, NULL) and looks
// only at ENOSYS vs anything else, or creates an fd (tiny BPF map, userfaultfd, socket) and closes it.
use std::ffi::c_long;
use std::io::Error;

extern "C" {
    fn syscall(num: c_long, ...) -> c_long;
    fn close(fd: i32) -> i32;
    fn dup(fd: i32) -> i32;
    fn socket(d: i32, t: i32, p: i32) -> i32;
    fn ioctl(fd: i32, req: u64, ...) -> i32;
}

fn errno() -> i32 { Error::last_os_error().raw_os_error().unwrap_or(0) }
fn ename(e: i32) -> String {
    let n = match e {
        1 => "EPERM", 2 => "ENOENT", 3 => "ESRCH", 7 => "E2BIG", 9 => "EBADF", 12 => "ENOMEM", 13 => "EACCES",
        14 => "EFAULT", 19 => "ENODEV", 22 => "EINVAL", 24 => "EMFILE", 38 => "ENOSYS", 42 => "ENOMSG",
        93 => "EPROTONOSUPPORT", 94 => "ESOCKTNOSUPPORT", 95 => "EOPNOTSUPP", 97 => "EAFNOSUPPORT", _ => "",
    };
    if n.is_empty() { format!("errno{}", e) } else { n.to_string() }
}
// present = the syscall exists (anything but ENOSYS)
fn present(name: &str, r: c_long) {
    let e = if r < 0 { errno() } else { 0 };
    if r >= 0 { unsafe { if r > 2 { close(r as i32); } } }
    println!("KQ sys.{} {} {}", name, if e == 38 { "ENOSYS" } else { "ok" }, if e != 0 { ename(e) } else { "0".into() });
}

#[repr(C)]
struct MapCreate { map_type: u32, key_size: u32, value_size: u32, max_entries: u32, rest: [u32; 14] }
fn bpf_map(name: &str, t: u32, k: u32, v: u32, n: u32) {
    let a = MapCreate { map_type: t, key_size: k, value_size: v, max_entries: n, rest: [0; 14] };
    let r = unsafe { syscall(280, 0 as c_long, &a as *const MapCreate, std::mem::size_of::<MapCreate>() as c_long) };
    if r >= 0 { unsafe { close(r as i32); } println!("KQ bpf.{} ok created", name); } else { println!("KQ bpf.{} {}", name, ename(errno())); }
}

#[repr(C)]
struct UffdApi { api: u64, features: u64, ioctls: u64 }
fn uffd() {
    // O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY (5.11+); retry without the mode flag for older kernels
    let mut r = unsafe { syscall(282, (0o2000000 | 0o4000 | 1) as c_long) };
    let mut mode = "user_mode_only";
    if r < 0 && errno() == 22 { r = unsafe { syscall(282, (0o2000000 | 0o4000) as c_long) }; mode = "no_user_mode_flag"; }
    if r < 0 { println!("KQ uffd.open {}", ename(errno())); return; }
    let fd = r as i32;
    let mut a = UffdApi { api: 0xAA, features: 0, ioctls: 0 };
    let x = unsafe { ioctl(fd, 0xC018AA3F, &mut a as *mut UffdApi) };
    if x < 0 { println!("KQ uffd.open ok {} api={}", mode, ename(errno())); unsafe { close(fd); } return; }
    let f = a.features;
    let has = |b: u32| if f & (1u64 << b) != 0 { 1 } else { 0 };
    // ART's concurrent mark-compact GC needs MINOR_SHMEM (bit 10); newer ART also uses UFFDIO_MOVE (bit 16)
    println!("KQ uffd.open ok {} features=0x{:x} missing_shmem={} minor_shmem={} move={} ioctls=0x{:x}",
        mode, f, has(5), has(10), has(16), a.ioctls);
    unsafe { close(fd); }
}

fn sock(name: &str, d: i32, t: i32, p: i32) {
    let r = unsafe { socket(d, t, p) };
    if r >= 0 { unsafe { close(r); } println!("KQ sock.{} ok", name); } else { println!("KQ sock.{} {}", name, ename(errno())); }
}

fn main() {
    unsafe {
        // close_range (5.9): close one fd we own
        let d = dup(1);
        let r = syscall(436, d as c_long, d as c_long, 0 as c_long);
        let e = if r < 0 { errno() } else { 0 };
        if r < 0 { close(d); }
        println!("KQ sys.close_range {} {}", if r == 0 { "ok" } else if e == 38 { "ENOSYS" } else { "err" }, if e != 0 { ename(e) } else { "0".into() });
        let z = 0 as c_long; let m = -1 as c_long;
        present("pidfd_open", syscall(434, z, z));                     // 5.3
        present("io_uring_setup", syscall(425, z, z));                 // 5.1
        present("openat2", syscall(437, m, z, z, z));                  // 5.6
        present("pidfd_getfd", syscall(438, m, z, z));                 // 5.6
        present("faccessat2", syscall(439, m, z, z, z));               // 5.8
        present("process_madvise", syscall(440, m, z, z, z, z));       // 5.10
        present("epoll_pwait2", syscall(441, m, z, z, z, z, z));       // 5.11
        present("landlock_create_ruleset", syscall(444, z, z, z));     // 5.13
        present("process_mrelease", syscall(448, m, z));               // 5.15
        present("futex_waitv", syscall(449, z, z, z, z, z));           // 5.16
        present("cachestat", syscall(451, m, z, z, z));                // 6.5
        present("mseal", syscall(462, z, z, z));                       // 6.10
    }
    bpf_map("array", 2, 4, 8, 1);        // control: any BPF map at all (EPERM = not allowed to probe)
    bpf_map("ringbuf", 27, 0, 0, 4096);  // BPF_MAP_TYPE_RINGBUF (5.8)
    uffd();
    sock("vsock", 40, 1, 0);             // AF_VSOCK
    sock("netlink_kfreecess", 16, 3, 27); // Samsung freecess (no message is sent: nothing registers)
    sock("netlink_sdp_fs", 16, 3, 28);   // Knox SDP_FS_HANDLER
    sock("netlink_fips_crypto", 16, 3, 29);
    sock("qrtr", 42, 2, 0);              // AF_QIPCRTR
}
