# Rede (app de iPhone para a rede de casa)

App nativo (SwiftUI, iOS 26, Liquid Glass) que mostra o estado do roteador AX3600 e mede velocidades.

- **Painel:** internet (PPPoE, há quanto tempo, IP público, prefixo IPv6, DNS), as 4 portas (velocidade, quedas, CRC,
  zerar contadores com toque longo), quantos aparelhos em cada banda, roteador (ligado há, carga, memória) e
  **Reiniciar o roteador** (com confirmação).
- **Aparelhos:** 5 GHz, 2,4 GHz, Cabo (em árvore: cada porta com os aparelhos atrás dela, como o roteador IoT e
  o GT-SRV; toque na porta para abrir ou fechar) e Controle. Nome, IP, MAC, sinal,
  taxa do link, tráfego atual (📌 = IP fixo). **Tocar** abre a ficha: nome e IP fixo, gravados no roteador (os mesmos da
  tela "DHCP static IP assignment" e do app Mi WiFi). **Arrastar para a esquerda** bloqueia no Wi-Fi (até a metade
  mostra o botão; até o fim, executa).
- **Aprovação (terceiro modo do Controle):** quem tem a senha conecta, mas aparelho fora da lista de autorizados fica
  **em quarentena** (só DHCP; sem internet, sem os outros aparelhos e sem o roteador) até ser aprovado. Em ~30 s chega
  um **push do próprio app** ("Aparelho novo no Wi-Fi"), com os botões Aprovar e Recusar ao segurar o aviso; tocar abre
  a aba Controle. Na lista, arrastar para a direita aprova e para a esquerda recusa.
- **Na aba Controle,** pendentes e conectados ficam à vista; autorizados fora do ar e bloqueados ficam atrás de um botão
  cada. Para quem está fora do ar, arrastar para um lado bloqueia/desbloqueia e para o outro **esquece** (`?a=forget`,
  tira das duas listas).
- **Consulta de MAC:** buscar um MAC (ou só o começo, 6+ dígitos) mostra o fabricante pelo prefixo e se o endereço é
  aleatório (2º dígito 2, 6, A ou E = inventado pelo aparelho, sem fabricante). Aparelho sem nome mostra o fabricante na
  lista. A tabela (`App/oui.txt`) é baixada pelo workflow a cada build (Wireshark, ou IEEE); o que não estiver nela o app
  pergunta ao `api.macvendors.com` e guarda.
- **Controle (acesso ao Wi-Fi):** dois modos. *Lista de bloqueio*: qualquer um com a senha entra, menos os bloqueados.
  *Só autorizados*: só a lista entra. O botão "Autorizar N de M conectados" copia para a lista de autorizados quem
  está no Wi-Fi e ainda não está nela (quando todos já estão, ele mostra isso e fica desativado). Trocar de modo não derruba quem continua permitido; só quem ficou de fora cai. As duas listas ficam
  guardadas no roteador.
- **Velocidade:** iPhone → Internet (Cloudflare), Roteador → Internet, GT-SRV → Internet (cabo), iPhone ↔ Roteador
  (só o Wi-Fi) e iPhone ↔ GT-SRV. Download, upload e latência; os últimos resultados ficam guardados.

## Como as peças se falam

```
iPhone ──(em casa)──────────────► roteador 10.0.0.1:8077   (API /nm, token no cabeçalho X-NM-Token)
   │  └──────────────────────────► GT-SRV 10.0.0.129:9092   (teste de velocidade)
   └──(fora, Tailscale)──────────► GT-SRV 100.91.24.1:9092 ──► /router/... repassa ao roteador
```

O app tenta o roteador direto; se não achar, usa a ponte do GT-SRV pela Tailscale. O token só é enviado depois que o
endereço se identifica (`/nm/id`), para não vazar numa rede de fora que também use 10.0.0.1.

## Pastas

| Pasta | O quê | Onde roda |
|---|---|---|
| `App/` | o app (Swift) | iPhone |
| `roteador/` | API (`api.lua`, CGI pelo nginx do roteador), `site.nginx.tpl`, `netmon.init`, `instalar.sh`, `desinstalar.sh` | AX3600 (`/etc/netmon`, `/etc/init.d/netmon`) |
| `servidor-gt-srv/` | `server.js` + `docker-compose.yml` (container `rede-srv`, porta 9092) | GT-SRV |
| `PARA-A-PASTA-.github-workflows/` | `build-ipa.yml` (vai para `.github/workflows/` à mão) | GitHub Actions |

## Instalar

### 1. Roteador (do WSL do notebook)

```bash
cd /mnt/c/claudin/gtm/2026/random/rede-ios
O="-oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1"
tar -cf - roteador | ssh $O root@10.0.0.1 "rm -rf /tmp/roteador; tar -C /tmp -xf - && sh /tmp/roteador/instalar.sh"
```

(Vai por `tar` dentro do `ssh`, sem `scp`: o dropbear antigo do roteador não fala o protocolo novo do `scp`.)

O fim da saída mostra o **TOKEN DO APP** (cole em Ajustes, no app). Para ver de novo: `cat /etc/netmon/token`.
Remover: `sh /tmp/roteador/desinstalar.sh` (com a pasta copiada de novo para `/tmp`).

### 2. GT-SRV

Copie `servidor-gt-srv` para `C:\Users\GTM\mover\rede-srv` no GT-SRV e, no WSL de lá:

```bash
mkdir -p ~/rede-srv && cp /mnt/c/Users/GTM/mover/rede-srv/* ~/rede-srv/
cd ~/rede-srv && docker compose up -d && curl -s http://127.0.0.1:9092/id
```

Teste de internet fora do Docker (no container a saída fica em ~100 Mb/s): o mesmo `server.js` roda também no WSL,
como serviço `rede-teste` (porta 9093), e o container repassa o `/wantest` para ele (`WANTEST_URL` no compose).
O teste vai até a Cloudflare, que pela TIM fica a ~60 ms (o fast.com mede contra servidores do Netflix dentro da TIM,
a 2 ms, e por isso dá mais): 12 conexões no download, 6 no upload, e os 2 primeiros segundos descartados.

```bash
sudo cp ~/rede-srv/rede-teste.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now rede-teste
curl -s http://127.0.0.1:9093/id
```

Firewall do Windows (PowerShell como administrador, no GT-SRV):

```powershell
New-NetFirewallRule -DisplayName "Rede 9092 (LAN + Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 9092 -RemoteAddress 10.0.0.0/24,100.64.0.0/10 -Action Allow -Profile Any
```

### 3. App (TestFlight)

Molde do `nfsu2-ios` (assinatura gerenciada pela Apple; ver `Manuais/MANUAL-APP-EXPO-BUILDS.md`, seção 9).
Bundle ID `com.gtm.rede`.

## Detalhes que importam

- **Roteador:** tudo em `/etc` (persistente). A cada boot o `netmon.init` recria o que fica na RAM: o arquivo de
  8 MB do teste (`/tmp/netmon/blob`) e o link `/www/cgi-bin/netmon`. ⚠️ Não trocar por um arquivo esparso grande: no
  kernel 4.4 do roteador, o `sendfile` de arquivo esparso em tmpfs ocupa a RAM de verdade. Em 10/11/2026 um arquivo
  esparso de 256 MB encheu a memória (o roteador tem ~400 MB, ~130 MB livres) e travou o roteador no primeiro teste. O nginx do roteador
  ganha uma linha `include /etc/netmon/*.nginx;`; se o `nginx -t` falhar, o script desfaz sozinho.
- **Teste do roteador para a internet:** o `curl` do roteador não tem certificados raiz (usa `-k`) e o processador
  limita a medição (~250 Mb/s em 4 fluxos, medido em 10/11/2026). Por isso existe o teste pelo GT-SRV (cabo).
- **Teste iPhone ↔ Roteador:** download do arquivo de 8 MB repetido; upload em pedaços de 4 MB que o nginx lê inteiros antes de
  responder (repasse para `/nm/sink`).
- **Acesso ao Wi-Fi:** `?a=block|unblock&mac=…`, `?a=snapshot` e `?a=mode&m=allow|deny` (só POST). As listas ficam
  em `/etc/netmon/acl_deny` e `/etc/netmon/acl_allow`; a do modo ativo é copiada para `wireless.@wifi-iface[0/1].maclist`
  com `macfilter='deny'` ou `'allow'`, que o firmware aplica no boot (`/lib/wifi/qcawificfg80211.sh`, lista "_sec" do
  chip). Na hora: `maccmd_sec 3` (limpa), `addmac_sec` de cada um, `maccmd_sec 1|2` e `kickmac` só de quem ficou de fora
  (pelo `cfg80211tool`, ou `iwpriv` se ele não existir). A lista do chip só vale para novas conexões, então trocar de
  modo não derruba quem continua permitido. Proteções: o aparelho que está usando o app não pode se bloquear e entra
  sozinho na lista ao ligar "só autorizados"; ligar com a lista vazia é recusado. Vale para 5 GHz e 2,4 GHz do AX3600; o Wi-Fi do roteador IoT é outro
  aparelho. É bloqueio por MAC: quem sabe a senha e troca o endereço (MAC aleatório) entra de novo; nesse caso, trocar a
  senha do Wi-Fi.
- **Nomes e IP fixo:** `?a=name&mac=…&name=…`, `?a=static_set&mac=…&ip=…`, `?a=static_del&mac=…` (só POST).
  Nomes no banco SQLite da Xiaomi (`/etc/xqDb`, tabela `DEVICE_INFO`: `NICKNAME` = dado pelo usuário, `ONAME` = o que o
  aparelho informa), pelo módulo `lsqlite3` do Lua do roteador (não há `sqlite3` de linha de comando). IP fixo nos dois
  lugares onde a Xiaomi grava: `/etc/config/macbind` (a lista da tela) e `/etc/config/dhcp` (o que o `dnsmasq` usa),
  seção = MAC sem ":", e `dnsmasq reload` (~1 s, ninguém cai). IP novo só vale quando o aparelho renova o DHCP.
- **Modo aprovação, por dentro:** o modo fica em `/etc/netmon/acl_mode` (`deny`, `allow` ou `approve`); no `approve`
  o chip do Wi-Fi fica em lista de bloqueio e o firewall ganha as cadeias `netmon_q` (FORWARD) e `netmon_qi` (INPUT), em
  IPv4 e IPv6: autorizados passam (`-m mac`), o resto que entra por `wl0`/`wl1` (`-m physdev`) é descartado, menos DHCP.
  Funciona para o tráfego entre aparelhos porque o roteador tem `bridge-nf-call-iptables=1`. Limite: dois aparelhos na
  **mesma banda** conversam direto pelo chip do Wi-Fi, sem passar pela bridge. O vigia (`/etc/netmon/vigia.sh`, serviço
  procd do `netmon.init`, a cada 15 s) refaz as cadeias se uma recarga do firewall as apagar e manda cada pendente novo
  (uma vez) ao `rede-srv`: `POST /evento` com o token do roteador. Endereço do rede-srv: `/etc/netmon/notify_url`
  (padrão `http://10.0.0.129:9092/evento`).
- **Push:** o app registra o token de push no `rede-srv` (`POST /push/registrar`, com o token do roteador). O `rede-srv`
  manda pela Apple (APNs, HTTP/2 + JWT ES256, sem bibliotecas), tópico `com.gtm.rede`. O App ID precisa de "Push
  Notifications" ligado; o workflow assina com `App/Rede.entitlements` (`aps-environment: production`, gerado pelo
  XcodeGen). Segredos no `~/rede-srv/.env` do GT-SRV (fora do repositório): `NM_TOKEN` (o token do roteador),
  `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8_B64` (a mesma chave de push do Porta Fidei, que vale para todos os apps da
  conta) e `APNS_TOPIC=com.gtm.rede`. Tokens de push em `~/rede-srv/dados/tokens.json`.
- **Portas:** os contadores e o reset são os mesmos do rodapé e da seção "Port status" da interface do roteador
  (`/etc/wanlink.base` e `/etc/wanlink/base.ethX`).
