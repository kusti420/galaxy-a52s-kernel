#!/bin/busybox sh
# iontest with every output line copied to kmsg (ramoops keeps it across a reset). $1 = 64|32, $2.. = flags
cd "${0%/*}"; . ./common.sh; chmod 755 iontest*; b=$1; shift
ld s1a; sh /p/mkdevs; ls -l /dev/ion
./iontest$b "$@" 2>&1 | while IFS= read -r l; do echo "$l"; echo "ion$b: $l" > /dev/kmsg; done
k "iontest$b done"
