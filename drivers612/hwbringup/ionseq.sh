#!/bin/busybox sh
# secure ION cases one by one, each step announced in kmsg first. Args: case names to run, in order
cd "${0%/*}"; . ./common.sh; chmod 755 ionone64; ld s1a; sh /p/mkdevs
one() { k "ionone $1: alloc mask $2 flags $3 ${4} MiB, hold 3 s"; ./ionone64 $2 $3 $4 3 2>&1; k "ionone $1: closed, wait 6 s (release / deferred free)"; sleep 6; k "ionone $1: survived"; }
for c in "$@"; do case $c in
  pixel)     one pixel 400 80080000 1;;
  nonpixel)  one nonpixel 400 80100000 1;;
  bitstream) one bitstream 400 80040000 1;;
  camera)    one camera 400 80200000 1;;
  touch)     one touch 400 80020000 1;;
  secdisp)   one secdisp 800 82000000 1;;
  qsecom)    one qsecom 80 0 1;;
esac; done
