#!/bin/sh
# Instala a API do app Rede no AX3600. Rodar no roteador: sh /tmp/roteador/instalar.sh
cd "$(dirname "$0")" || exit 1
mkdir -p /etc/netmon
cp api.lua site.nginx.tpl vigia.sh /etc/netmon/
cp netmon.init /etc/init.d/netmon
chmod 755 /etc/init.d/netmon /etc/netmon/api.lua
/etc/init.d/netmon enable
/etc/init.d/netmon start || exit 1
sleep 1
T=$(cat /etc/netmon/token)
H="X-NM-Token: $T"
B=http://127.0.0.1:8077/nm
echo "== conferindo"
echo "id: $(curl -s $B/id)"
curl -s -o /dev/null -w "api sem token (esperado 403): %{http_code}\n" $B/api
curl -s -H "$H" -o /tmp/netmon/t.json -w "api com token (esperado 200): %{http_code}\n" "$B/api?a=all"
echo "inicio da resposta: $(head -c 120 /tmp/netmon/t.json)"
rm -f /tmp/netmon/t.json
curl -s -H "$H" -r 0-4194303 -o /dev/null \
	-w "download 4 MB (esperado 4194304 206): %{size_download} %{http_code}\n" $B/dl
dd if=/dev/zero bs=1M count=4 2>/dev/null | curl -s -H "$H" -H "Expect:" \
	--data-binary @- -o /dev/null -w "upload 4 MB (esperado 4194304 204): %{size_upload} %{http_code}\n" $B/up
curl -s -H "$H" -o /dev/null -w "bloqueio sem POST (esperado 405): %{http_code}\n" \
	"$B/api?a=block&mac=00:00:00:00:00:00"
echo "Wi-Fi: modo $(uci -q get wireless.@wifi-iface[0].macfilter), lista: $(uci -q get wireless.@wifi-iface[0].maclist)"
free | sed -n 2p
echo "vigia: $(ps w | grep -c '[v]igia.sh') rodando"
ls /etc/rc.d | grep netmon
echo
echo "TOKEN DO APP: $T"
