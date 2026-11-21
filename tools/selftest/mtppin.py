#!/usr/bin/env python3
"""MTP check of ONE pinned USB device (never any other phone on the PC).

  mtppin.py info  <busnum> <devnum>   open only the MTP device at that bus/devnum, print serial, model,
                                      storage list; exit 0 = session opened, 2 = not found, 3 = open failed

mtp-detect opens EVERY MTP device on the bus; this uses libmtp's raw-device API and opens only the raw
device whose bus_location/devnum equal the pinned phone's sysfs busnum/devnum.
"""
import ctypes as C, ctypes.util, sys

class Entry(C.Structure):
    _fields_ = [('vendor', C.c_char_p), ('vendor_id', C.c_uint16), ('product', C.c_char_p),
                ('product_id', C.c_uint16), ('device_flags', C.c_uint32)]

class Raw(C.Structure):
    _fields_ = [('device_entry', Entry), ('bus_location', C.c_uint32), ('devnum', C.c_uint8)]

class Storage(C.Structure):
    pass
Storage._fields_ = [('id', C.c_uint32), ('StorageType', C.c_uint16), ('FilesystemType', C.c_uint16),
                    ('AccessCapability', C.c_uint16), ('MaxCapacity', C.c_uint64),
                    ('FreeSpaceInBytes', C.c_uint64), ('FreeSpaceInObjects', C.c_uint64),
                    ('StorageDescription', C.c_char_p), ('VolumeIdentifier', C.c_char_p),
                    ('next', C.POINTER(Storage)), ('prev', C.POINTER(Storage))]

class Dev(C.Structure):  # leading members of LIBMTP_mtpdevice_t only
    _fields_ = [('object_bitsize', C.c_uint8), ('params', C.c_void_p), ('usbinfo', C.c_void_p),
                ('storage', C.POINTER(Storage))]

def info(bus, dev):
    lib = C.CDLL(ctypes.util.find_library('mtp') or 'libmtp.so.9')
    lib.LIBMTP_Init()
    lib.LIBMTP_Detect_Raw_Devices.argtypes = [C.POINTER(C.POINTER(Raw)), C.POINTER(C.c_int)]
    lib.LIBMTP_Open_Raw_Device_Uncached.argtypes = [C.POINTER(Raw)]
    lib.LIBMTP_Open_Raw_Device_Uncached.restype = C.POINTER(Dev)
    for f in ('LIBMTP_Get_Serialnumber', 'LIBMTP_Get_Modelname'):
        getattr(lib, f).argtypes = [C.POINTER(Dev)]; getattr(lib, f).restype = C.c_void_p
    lib.LIBMTP_Get_Storage.argtypes = [C.POINTER(Dev), C.c_int]
    lib.LIBMTP_Release_Device.argtypes = [C.POINTER(Dev)]
    raws = C.POINTER(Raw)(); n = C.c_int(0)
    lib.LIBMTP_Detect_Raw_Devices(C.byref(raws), C.byref(n))
    pick = None
    for i in range(n.value):
        if raws[i].bus_location == bus and raws[i].devnum == dev:
            pick = raws[i]
    if pick is None:
        print('no MTP raw device at bus %d dev %d (%d MTP devices on the PC, none opened)' % (bus, dev, n.value))
        return 2
    d = lib.LIBMTP_Open_Raw_Device_Uncached(C.byref(pick))
    if not d:
        print('Unable to open the MTP device at bus %d dev %d' % (bus, dev)); return 3
    s = lib.LIBMTP_Get_Serialnumber(d); m = lib.LIBMTP_Get_Modelname(d)
    print('   Serial number: %s' % (C.string_at(s).decode(errors='replace') if s else '?'))
    print('   Model: %s' % (C.string_at(m).decode(errors='replace') if m else '?'))
    if lib.LIBMTP_Get_Storage(d, 0) == 0:
        st = d.contents.storage
        while st:
            print('      StorageDescription: %s' % (st.contents.StorageDescription or b'').decode(errors='replace'))
            print('      MaxCapacity: %d' % st.contents.MaxCapacity)
            print('      FreeSpaceInBytes: %d' % st.contents.FreeSpaceInBytes)
            st = st.contents.next
    lib.LIBMTP_Release_Device(d)
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != 'info':
        print(__doc__); sys.exit(1)
    sys.exit(info(int(sys.argv[2]), int(sys.argv[3])))
