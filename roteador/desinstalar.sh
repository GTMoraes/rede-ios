#!/bin/sh
# Remove a API do app Rede. Rodar no roteador: sh /tmp/roteador/desinstalar.sh
/etc/init.d/netmon stop 2>/dev/null
/etc/init.d/netmon disable 2>/dev/null
# tira a quarentena do firewall, se estiver ligada
for ipt in iptables ip6tables; do
	while $ipt -D FORWARD -j netmon_q 2>/dev/null; do :; done
	while $ipt -D INPUT -j netmon_qi 2>/dev/null; do :; done
	$ipt -F netmon_q 2>/dev/null; $ipt -X netmon_q 2>/dev/null
	$ipt -F netmon_qi 2>/dev/null; $ipt -X netmon_qi 2>/dev/null
done
rm -f /etc/init.d/netmon /www/cgi-bin/netmon /tmp/netmon/blob
sed -i '\|/etc/netmon/\*.nginx|d' /etc/nginx/nginx.conf
rm -rf /etc/netmon
P=$(ps w | grep '[n]ginx: master' | awk '{print $1}')
[ -n "$P" ] && kill -HUP $P
echo "removido"
