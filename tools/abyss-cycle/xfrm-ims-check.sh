#!/system/bin/sh
# Can this kernel build the IPsec SAs an IMS stack asks for (3GPP TS 33.203 transport-mode ESP)?
# Adds + deletes test SAs on loopback only (unique SPIs 0x7a52xxxx), touches no real SA. Run as root.
K16=0x00112233445566778899aabbccddeeff
K20=0x00112233445566778899aabbccddeeff00112233
K24=0x00112233445566778899aabbccddeeff0011223344556677
i=0
try() { # fam src dst authalg key encalg enckey
	i=$((i+1)); spi=$((0x7a520000 + i))
	if [ "$6" = null ]; then
		ip $1 xfrm state add src $2 dst $3 proto esp spi $spi reqid $spi mode transport auth-trunc "$4" $5 96 enc "ecb(cipher_null)" "" 2>/tmp/xe
	else
		ip $1 xfrm state add src $2 dst $3 proto esp spi $spi reqid $spi mode transport auth-trunc "$4" $5 96 enc "$6" $7 2>/tmp/xe
	fi && r=OK || r="FAIL $(cat /tmp/xe)"
	ip $1 xfrm state delete src $2 dst $3 proto esp spi $spi 2>/dev/null
	echo "$1 $4 + $6: $r"
}
for fam in -4 -6; do
	[ $fam = -4 ] && { s=127.0.0.1; d=127.0.0.1; } || { s=::1; d=::1; }
	try $fam $s $d "hmac(md5)" $K16 null
	try $fam $s $d "hmac(md5)" $K16 "cbc(aes)" $K16
	try $fam $s $d "hmac(md5)" $K16 "cbc(des3_ede)" $K24
	try $fam $s $d "hmac(sha1)" $K20 null
	try $fam $s $d "hmac(sha1)" $K20 "cbc(aes)" $K16
	try $fam $s $d "hmac(sha1)" $K20 "cbc(des3_ede)" $K24
done
# policy with a socket-less selector, as IpSecService does for transport mode it uses per-socket policies
ip -6 xfrm policy add src ::1/128 dst ::1/128 proto tcp sport 5060 dir out tmpl proto esp mode transport reqid 0x7a52ffff 2>/tmp/xe && echo "-6 policy add: OK" || echo "-6 policy add: FAIL $(cat /tmp/xe)"
ip -6 xfrm policy delete src ::1/128 dst ::1/128 proto tcp sport 5060 dir out 2>/dev/null
echo "xfrm_stat (non-zero):"; awk '$2 != 0' /proc/net/xfrm_stat
echo "live SAs: $(ip xfrm state 2>/dev/null | grep -c '^src')  live policies: $(ip xfrm policy 2>/dev/null | grep -c '^src')"
