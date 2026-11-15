# Mainline track: changes on top of sc7280-mainline `sc7280-7.3.y`

Base: `https://github.com/sc7280-mainline/linux`, branch `sc7280-7.3.y`, commit `1cd0a2a93ac5`
(tag `v7.3.0-sc7280`). The tree is a git worktree of `linux/` at `linux-7.3/` (branch
`a52sxq-7.3`) and is not part of this repository. Recreate it:

    git -C linux fetch --depth 1 origin sc7280-7.3.y
    git -C linux worktree add -b a52sxq-7.3 ../linux-7.3 origin/sc7280-7.3.y
    git -C linux-7.3 am ../patches/mainline-7.3/*.patch

| patch | why |
|---|---|
| 0001 COMMAND_LINE_SIZE 4096 | the Samsung ABL appends ~3 KB (needed for any later real boot) |
| 0002 of/kexec alternative base FDT | `/sys/firmware/kexec_fdt`, same code as the proven ACK 6.18 harness patch (depth fix included); lets this kernel kexec a next one |
| 0003 machine_kexec `__nocfi` | kCFI fault on the physical-address jump (seen with ACK); no effect without CFI |
| 0004 a52ram earlycon | `earlycon=a52ram,0xf0be0000`, read back by the harness as `/proc/a52ram` |
| 0005 `sm7325-samsung-a52sxq.dts` + Makefile | the 6.18 harness board file unchanged, plus the QDSS nodes new in 7.3's kodiak.dtsi disabled |

Not carried from `patches/ack-6.18` (not on this boot path): the of_iommu resv-region fix (for
the downstream vendor IOMMU DT only) and the SELinux `system:firmware_load` change (Android only).

`a52sxq-ml.config`: fragment on top of `fp5_defconfig` (`./build-mainline.sh` merges and checks
it). `FIRST-RUN.txt`: the exact first on-phone command and its expected outcomes (copy of
`out-ml/FIRST-RUN.txt`). `./sync-ml-patches.sh` regenerates the numbered patches from the worktree.
