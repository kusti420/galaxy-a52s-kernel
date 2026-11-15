# Changes on top of ACK android17-6.18

`ack/` is a shallow clone of `https://android.googlesource.com/kernel/common`, branch
`android17-6.18` (commit 00c8666046c2, 6.18.33), and is not part of this repository.
To recreate it: clone that branch into `ack/`, apply `0001-a52sxq-tracked-changes.diff`, and copy

- `sm7325-samsung-a52sxq.dts` to `ack/arch/arm64/boot/dts/qcom/`
- `a52sxq_gki.fragment` to `ack/arch/arm64/configs/`

`./sync-ack-patches.sh` refreshes this directory from the working tree.
