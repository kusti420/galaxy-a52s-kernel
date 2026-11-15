# LTE data on the real 6.12 boot (rb12, phone 1): lossy ping, then a ping that hangs

State 2026-11-15 ~13:00. Analysis offline (logs only, no phone access). A fix is built as
`drivers612/realboot/out/rb13`. It is NOT flashed and NOT run.

Symptom (rb12 real boot, LineageOS userspace, Samsung RIL, vendor ipacm, the carrier LTE, APN
internet.emt.ee): rmnet_data0 gets 10.51.200.113/30 and `ping` shows 60-80 % loss with rtt
up to 3 s. Later `ping -c 8 -W 2 1.1.1.1` hangs without printing anything. The kexec
rehearsal of the same build had 4/4 at ~23 ms, and the kernel-only qmi-nas test (busybox
ping) was clean.

Logs: `logs/rb12-p1-lte/{dmesg,net,ipa-debugfs,logcat-data}.txt`, rehearsal
`logs/rh612p1m-dmesg.txt`. The real-boot dmesg only starts at 115 s: the DIAG cmdline
(`initcall_debug ignore_loglevel`) and the wlan driver filled the buffer. So the IPA/rmnet
setup lines of the real boot are lost. There are no IPA, GSI, SMMU, rmnet or avc lines
between 115 s and 394 s.

## H1 (root cause, proven from the code and the counters): no WAN TX completion ever runs

### Code

`dataipa` r30, `ipa_v3/ipa_dp.c`, `ipa_gsi_irq_tx_notify_cb()`, GSI EOT event of a producer
pipe. The NAPI branch only schedules the poll:

    } else if (ipa_net_initialized && sys->napi_tx_enable) {
        if(!atomic_cmpxchg(&tx_pkt->sys->in_napi_context, 0, 1))
            napi_schedule(&tx_pkt->sys->napi_tx);
    } else {
        atomic_inc(&tx_pkt->sys->xmit_eot_cnt);      /* only the tasklet path counts */
        tasklet_schedule(&tx_pkt->sys->tasklet);
    }

The poll it schedules is `ipa3_aux_napi_tx_complete()` -> `ipa3_napi_tx_complete()`. It runs
`while (budget > 0 && atomic_read(&sys->xmit_eot_cnt) > 0)`, so with a count of 0 it
completes nothing and returns.

The 5.4 driver (`kernel/samsung/sm7325/techpack/dataipa`) does `atomic_inc(xmit_eot_cnt)`
before the branch. Qualcomm's 6.12 trees only enable `qcom,tx-napi` together with
`qcom,tx-poll`, which takes the first branch (waipio, pikachu, seraph in
`donors/clo-devicetree-6.12`). So "tx-napi without tx-poll" was never tested on r30. Our IPA
node is the phone's 5.4 node, which has `qcom,tx-napi` and no `qcom,tx-poll`. That pair puts
APPS_WAN_PROD (rmnet_ipa0) and APPS_LAN_PROD on this dead path. The command pipe and
WAN_LOW_LAT_PROD (rmnet_ctl, the QMAP/DFC commands) have NAPI off. They use the tasklet and
complete normally. The GSI ring itself still advances (`gsi_process_chan` increments rp for
TO_GSI channels without tx_poll), so packets do reach the modem. What is never freed is the
IPA layer's state for each packet: the tx wrapper, the DMA mapping and the **skb**.

### Counters from the stuck state (logs/rb12-p1-lte)

    ipa stats:   hw_tx=242   tx_compl=93   sw_tx=0
    rmnet_ipa0:  TX 149 packets
    242 - 93 = 149 = every packet rmnet_ipa0 ever sent

`hw_tx` counts WAN_PROD plus WAN_LOW_LAT_PROD (rmnet_ctl) and nothing else (the only
`ipa_tx_dp()` callers loaded). So all 93 completions belong to the rmnet_ctl pipe, and not
one of the 149 data packets was completed. Also `act_clnt=1` at idle: rmnet_ipa's PM handle
is released only when `outstanding_pkts == 0`, which never happens again.

### What a never-freed skb does, and how that matches the symptoms

1. **Socket send memory stays charged** (rmnet does not `skb_orphan`). Android's ping
   (`external/iputils`, `sock_setbufs()`) sets `SO_SNDBUF` to about one packet. The kernel
   raises that to its minimum of 4608 B, which is about 4 ICMP skbs. `SO_SNDTIMEO` is 1 s, and
   on `EAGAIN` ping loops (`tokens += interval; return MININTERVAL`) without counting a
   transmission. So each ping process sends about 4 probes. The 5th send never succeeds, and
   `ping -c 8` waits forever: the "hang without printing" (`| tail` also held back the output
   lines). The rehearsal check sent exactly 4 (4/4). busybox ping in the kernel-only test
   keeps the default 208 KB sndbuf. `/proc/net/snmp` agrees: `Icmp OutEchos 34 / InEchoReps 33`.
   The probes that left were nearly all answered, so the "loss" is mostly probes that were
   never sent, plus replies arriving after ping gave up.
2. **TCP stops retransmitting.** `__tcp_retransmit_skb()` -> `skb_still_in_host_queue()`
   refuses to resend while the fclone is still held by the driver, and here it is held for
   good. The first lost segment stalls a TCP connection permanently. TSQ also limits each
   socket to about 2 segments in flight on the host. Result: apps and Android validation
   see "connected but broken" data.
3. **Hard UL stop after 256 data packets since boot.** `ipa3_wwan_xmit()` stops the
   rmnet_ipa0 queue when `outstanding_pkts >= outstanding_high` (256, `OUTSTANDING_HIGH_DEFAULT`).
   Only the TX-complete callback wakes it again. At capture time the count was 149. Once it
   reaches 256, all mobile UL is dead until SSR or reboot. dmesg will then show
   `NETDEV WATCHDOG: rmnet_ipa0 ... transmit queue 0 timed out` and
   `[rmnet_ipa0] data stall in UL, 256 outstanding`.
4. Memory leaks (skb + IPA_TX_PKT_WRAPPER per UL packet). The IPA clock vote also stays up
   for good (`act_clnt=1`), which costs battery and may block IPA/system power collapse.

Why the rehearsal and the kernel-only test looked clean: too few UL packets per socket and in
total (4 pings, a few DNS queries, each query on a fresh socket). Same bug, below its
thresholds.

### Fix (built, not flashed)

`drivers612/conn/data/patches/0002-dataipa-tx-napi-count-eot.patch`, applied in
`src/dataipa`: one `atomic_inc(&tx_pkt->sys->xmit_eot_cnt)` in the NAPI branch, which is the
5.4 behaviour. `conn/data/build.sh`: 0 errors and 0 warnings. Only `ipam.ko` changes: the
other 12 modules are byte-identical to the build before, and 7 of them to the tested pack.
The ipam export/import CRC sections (`__kcrctab`, `__kcrctab_gpl`, `__version_ext_crcs`) are
identical, so the rmnet modules still bind.

- `drivers612/modem/out/pack-modem-txfix.tgz` = `pack-modem.tgz` with only `m/ipam.ko`
  replaced. (Not in git: out/ is ignored. To recreate it, untar the old pack and copy
  `conn/data/out/lib/modules/*/extra/ipam.ko` into `m/`.)
- `MODEM_PACK=$PWD/drivers612/modem/out/pack-modem-txfix.tgz DIAG=1 MODEM=1
  drivers612/realboot/build-realboot.sh rb13`: all checks pass.
  boot.img = rb12 (7a94e8b0...). vendor_boot d512941c... differs only by ipam.ko and the
  `realboot-base = "rb13"` marker (dtb otherwise identical, modules.load identical).
  dtbo 6080a523... differs only by the `realboot = "rb13"` marker. The add-on differs only by
  the build name in the rc comment, so there is no need to reinstall it.
- Flashing rb13 = rb12's procedure (vendor_boot + dtbo; boot unchanged). This needs the
  explicit OK. Rollback is as for rb12: `/cache/a52rb-rollback`.
- Alternative without a module change: drop `qcom,tx-napi` from the IPA node (tasklet path,
  the one the command and low-lat pipes prove works). This is not prepared, because
  build-realboot's modem-subtree check would need a deliberate allowance.

New behaviour to watch after the fix: completions now release rmnet_ipa's PM vote, so IPA
clock gating will happen for the first time on 6.12 (see H5).

## H2 (likely an extra factor for the multi-second rtt, not proven): RRC dormancy + DFC flow control

- logcat: the call flips ACTIVE <-> DORMANT about every 7 s. Twice it went DORMANT -> ACTIVE
  within about 0.12 s (12:31:24.986 -> 25.097 and 12:33:32.367 -> 32.495), which looks like
  RRC release, then UL data waiting, then a new connection setup.
- `tc -s qdisc show dev rmnet_data0`: txq `:2` (DFC bearer mq 1) has `requeues 9`. Its ACK
  queue `:11` (index 16 = 1 + ACK_MQ_OFFSET 15) carried 69 packets. Requeues mean the DFC
  disabled that queue while packets were waiting for a grant.
- H1 alone does not give a 3 s rtt for a probe that was actually sent. RRC/DRX or a DFC grant
  wait can. Check this after H1 is out of the way (experiment E6). It may simply be what 5.4
  does too: no 5.4 ping baseline on phone 1 exists yet.

## H3 (low): Wi-Fi + cellular and the ipacm rules

ipacm runs on the real boot. With Wi-Fi as the default network it treats wlan0 as the
backhaul and installs filter/route rules, then re-installs them when cellular takes over (the
logcat at 12:31:09 shows every request moving to cellular, and wlan stopped at 115 s).
Evidence so far: only `lan_rx_excp[NONE]=4` (4 DL packets routed to the apps LAN pipe). The
loss also happened after Wi-Fi was off. Experiment E7.

## H4 (low): rmnet_shs / rmnet_offload

There is no evidence against them. shs only steers RX between CPUs and offload coalesces TCP
(not ICMP). Both behaved the same in the clean rehearsal. Look only if E1-E6 leave something
unexplained.

## H5 (watch item, currently masked): IPA clock gating / ipa_pm

Because of H1 the rmnet_ipa PM client never deactivates (`act_clnt=1` at idle), so IPA clock
gating or missing interconnect votes cannot cause stalls today. After rb13 they can: check
`active_clients` / `pm_stats` and ping after 1-2 min idle and after screen-off.

## Experiments (key-free, on the running rb12 phone 1, no flash), in order

Prerequisite: Rooted debugging, `adb root`. Do not print SIM/UIM data.

- **E1, confirm H1 (read-only, 1 min).**

      adb shell 'grep -E "hw_tx|tx_compl" /sys/kernel/debug/ipa/stats; grep rmnet_ipa0 /proc/net/dev;
                 grep IPA_TX_PKT_WRAPPER /proc/slabinfo; cat /sys/kernel/debug/ipa/active_clients'
      adb shell 'ping -c 3 -w 5 1.1.1.1'      # then repeat the first command

  H1 is confirmed if `hw_tx - tx_compl` equals rmnet_ipa0's TX packet count, and after the
  ping `hw_tx` and the TX count went up by 3 while `tx_compl` did not (apart from rmnet_ctl
  traffic). The IPA_TX_PKT_WRAPPER active objects should be about the same as the outstanding
  count. H1 is refuted if `tx_compl` follows `hw_tx`.
- **E2, the ping hang is send memory.**

      adb shell 'cat /proc/net/icmp /proc/net/udp'   # tx_queue column (5th, before ':') != 0 on idle
                                                     # sockets bound to 71C8330A (10.51.200.113) = leaked skbs
      adb shell 'ping -c 20 -i 0.5 -w 15 1.1.1.1'           # H1: about 4 transmitted, then silence
      adb shell 'ping -S 200000 -c 20 -i 0.5 -w 15 1.1.1.1' # H1: 20 transmitted (big sndbuf)

  If both runs transmit 20, refute the socket part and look again at H2/H3.
- **E3, TCP retransmit suppression.**

      adb shell 'grep -A1 TcpExt: /proc/net/netstat'   # TCPSpuriousRtxHostQueues field
      adb shell 'ss -tmi'                              # skmem t<N> (wmem_alloc) stuck > 0 on idle sockets

  TCPSpuriousRtxHostQueues growing with use = H1 is hitting TCP.
- **E4, stopgap until rb13 (keeps UL from dying at 256; does not fix the leak).** Do it
  before rmnet_ipa0 reaches 256 TX packets:

      adb shell 'echo 1000000 > /sys/kernel/debug/rmnet_ipa/outstanding_high;
                 echo 1000032 > /sys/kernel/debug/rmnet_ipa/outstanding_high_ctl'

  If the queue already stopped (watch for NETDEV WATCHDOG in dmesg), only a reboot or modem
  SSR clears it. `ip link set rmnet_ipa0 down/up` calls `netif_start_queue()` but tears down
  Android's network: last resort only.
- **E5, after rb13 is flashed (explicit OK).** Repeat E1-E3. Expected: `tx_compl` follows
  `hw_tx`, the wrapper slab stays flat, `ping -c 20` without -S gives 20/20,
  TCPSpuriousRtxHostQueues stays flat, `act_clnt` goes to 0 when idle. Then H5: ping after
  2 min idle and after screen-off, and look for GSI/IPA errors in dmesg.
- **E6, H2 (works with the leak too, thanks to -S).** `ping -S 200000 -D -c 30 -i 0.2 1.1.1.1`
  against `... -i 1` and `... -i 3`. Run `logcat -b radio | grep DATA_CALL_LIST` alongside,
  plus DFC tracing:

      adb shell 'echo 1 > /sys/kernel/tracing/events/dfc/enable; cat /sys/kernel/tracing/trace_pipe'

  (`dfc_flow_ind` grant 0 / `dfc_flow_check` disabled). Spikes only at long intervals that
  line up with DORMANT -> ACTIVE mean radio/DRX (compare with a 5.4 baseline). Spikes that
  line up with grant-0 / flow-disabled events mean DFC. Clean at every interval: H1 was the
  whole story.
- **E7, H3.** `svc wifi disable` (already off: just confirm), then
  `cat /sys/kernel/debug/ipa/ip4_flt /sys/kernel/debug/ipa/ip4_rt` and
  `logcat -d | grep -i ipacm` with Wi-Fi on and off. As a last resort,
  `setprop ctl.restart vendor.ipacm`.

## Not the cause (checked)

- MTU 1500 (from the RIL), rmnet_ipa0 9216, qdisc mq + pfifo_fast with 0 drops and 0 backlog.
- No SMMU fault, no GSI channel error, no "ipa3_send"/"pipe stuck" lines in either boot.
- `lan_rx_excp` is all NONE. `wan_rx=0` is normal with NAPI/coalescing (that counter is
  bumped only on the legacy path).
- Rehearsal-only notes: `ipa_init_flt_rt_stats: SRAM partition too small` (FnR stats) and
  `Invalid source resource group #2` were present in the clean rehearsal as well.
  `ipa_pm_handle_suspend: Client IPA_CLIENT_TEST4_CONS woke up the system` (rehearsal 345 s)
  is a client-name mapping quirk of the suspend IRQ, harmless here.
