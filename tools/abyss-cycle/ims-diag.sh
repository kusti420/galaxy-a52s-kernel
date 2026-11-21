#!/bin/bash
# Redacted VoLTE/IMS evidence from a phone running ImsStack (root via /system/bin/su).
#   tools/abyss-cycle/ims-diag.sh <serial> <outdir>     (daily-diag.sh calls it)
# Read-only. Nothing that identifies the SIM or the subscriber is written: no SIP bodies
# (ImsStackN-SIP lines are dropped on the phone), sip:/tel: URIs, IMPI/IMPU, call-ids, branches,
# nonces and every run of 6+ digits are replaced; xfrm keys and all IP addresses are never printed.
set -u
S=${1:?serial}; D=${2:?outdir}; mkdir -p "$D"
SU() { adb -s "$S" shell "/system/bin/su -c '$1'"; }
red() { sed -E 's/(sips?|tel|urn):[^ ;>",)]*/\1:<r>/g; s/<r>[^ ]*@[^ ;>",]*/<r>/g; s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<r@r>/g;
	s/\b(call-id|Session-ID|via-branch|branch|nonce|cnonce|response|opaque|tag|username|realm|uri|RAND|AUTN|RES|AUTS|CK|IK)\b[=:(]+ *[^ ,;)}]*/\1=<r>/gI;
	s/(0x)?[0-9a-fA-F]{12,}/<hex>/g; s/[0-9]{6,}/<n>/g; s/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip4>/g; s/([0-9a-f]{1,4}:){3,}[0-9a-f:]*/<ip6>/gI'; }
{
echo "== ImsStack registration trail (logcat, redacted)"
SU 'logcat -d -b main,system,radio -s ImsStackN 2>/dev/null | grep -E "SIPMSG\[[0-9]\]=\{ IN|SIP-RSP|Registration_[A-Za-z]*(Failed|Updated|Started|Terminated)|ProcessAuth|ProcessAka|Aka response|AkaResult|IsimAuth|Authentication|SetBlockReason|ResetBlockReason|Registration_StateChanged|SetState :: old state|Create UE Spi|SA  NOT|established new SA|DestroyAllSas|SetUePortnSpi|Pcscf|PDN|Ipsec|IpSec"' | cut -c1-260 | red | tail -150
echo "== last block reasons per AoS app"
SU 'logcat -d -b main -s ImsStackN 2>/dev/null | grep PrintBlockReasons | tail -6' | cut -c1-260 | red
echo "== IPsec SAs (no keys, no addresses): count + mode/algorithms"
SU 'ip xfrm state 2>/dev/null' | awk '/^src/{n++} / mode /{for(i=1;i<=NF;i++) if($i=="mode") print "  mode", $(i+1)} /^\t(auth-trunc|auth|enc|aead) /{print "  " $1, $2, ($1=="auth-trunc" ? "trunc " $4 : "")} END{print "  SAs total:", n+0}' | sort | uniq -c
echo "  policies: $(SU 'ip xfrm policy 2>/dev/null | grep -c ^src')"
echo "== /proc/net/xfrm_stat (non-zero)"; SU 'awk "\$2 != 0" /proc/net/xfrm_stat'
echo "== rmnet / IMS PDN interfaces (addresses omitted)"
SU 'for i in /sys/class/net/rmnet_data*; do n=${i##*/}; st=$(cat $i/operstate); g6=$(ip -6 addr show dev $n scope global 2>/dev/null | grep -c inet6); g4=$(ip -4 addr show dev $n 2>/dev/null | grep -c "inet "); [ "$st$g6$g4" = "down00" ] || echo "  $n $st ipv4=$g4 ipv6-global=$g6 mtu=$(cat $i/mtu)"; done'
echo "== IMS data network (framework)"
SU 'dumpsys telephony.registry 2>/dev/null | grep -oE "mApnSetting=[^]]*\] *|apnName=[a-zA-Z.]+|ApnSetting: [^,]*,[^,]*" | grep -iE "ims" | sort | uniq -c | head -8' | red
SU 'dumpsys activity service com.android.phone 2>/dev/null | grep -iE "DataNetwork.*ims|apn=ims|IMS.*CONNECTED" | head -8' | cut -c1-200 | red
echo "== netfilter: non-zero DROP/REJECT counters (v4+v6, no addresses)"
SU 'for t in iptables ip6tables; do $t -w -t filter -L -v -n -x 2>/dev/null | awk -v t=$t "/^Chain/{c=\$2} (\$3==\"DROP\"||\$3==\"REJECT\") && \$1>0 {print \"  \" t, c, \$1\" pkts\", \$3}"; done' | head -30
} > "$D/ims.txt" 2>&1
echo "ims: $(grep -c . "$D/ims.txt") lines -> $D/ims.txt"
