#!/bin/sh
# Remove a API do app Rede. Rodar no roteador: sh /tmp/roteador/desinstalar.sh
/etc/init.d/netmon disable 2>/dev/null
rm -f /etc/init.d/netmon /www/cgi-bin/netmon /tmp/netmon/blob
sed -i '\|/etc/netmon/\*.nginx|d' /etc/nginx/nginx.conf
rm -rf /etc/netmon
P=$(ps w | grep '[n]ginx: master' | awk '{print $1}')
[ -n "$P" ] && kill -HUP $P
echo "removido"
