#!/bin/sh
# Vigia do modo aprovação do app Rede (ver a função watch em /etc/netmon/api.lua).
# Fora do modo aprovação, cada rodada só lê o modo e sai.
while true; do
	lua /etc/netmon/api.lua watch >/dev/null 2>&1
	sleep 15
done
