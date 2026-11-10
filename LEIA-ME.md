# Rede (app de iPhone para a rede de casa)

App nativo (SwiftUI, iOS 26, Liquid Glass) que mostra o estado do roteador AX3600 e mede velocidades.

- **Painel:** internet (PPPoE, há quanto tempo, IP público, prefixo IPv6, DNS), as 4 portas (velocidade, quedas, CRC,
  zerar contadores com toque longo), quantos aparelhos em cada banda, roteador (ligado há, carga, memória) e
  **Reiniciar o roteador** (com confirmação).
- **Aparelhos:** 5 GHz, 2,4 GHz e Cabo (inclui os aparelhos atrás do roteador IoT). Nome, IP, MAC, sinal, taxa do link,
  tráfego atual. Toque para dar um nome (fica só no iPhone).
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

Firewall do Windows (PowerShell como administrador, no GT-SRV):

```powershell
New-NetFirewallRule -DisplayName "Rede 9092 (LAN + Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 9092 -RemoteAddress 10.0.0.0/24,100.64.0.0/10 -Action Allow -Profile Any
```

### 3. App (TestFlight)

Molde do `nfsu2-ios` (assinatura gerenciada pela Apple; ver `Manuais/MANUAL-APP-EXPO-BUILDS.md`, seção 9).
Bundle ID `com.gtm.rede`.

## Detalhes que importam

- **Roteador:** tudo em `/etc` (persistente). A cada boot o `netmon.init` recria o que fica na RAM: o arquivo esparso
  de 256 MB do teste (`/tmp/netmon/blob`, não ocupa memória) e o link `/www/cgi-bin/netmon`. O nginx do roteador
  ganha uma linha `include /etc/netmon/*.nginx;`; se o `nginx -t` falhar, o script desfaz sozinho.
- **Teste do roteador para a internet:** o `curl` do roteador não tem certificados raiz (usa `-k`) e o processador
  limita a medição (~250 Mb/s em 4 fluxos, medido em 10/11/2026). Por isso existe o teste pelo GT-SRV (cabo).
- **Teste iPhone ↔ Roteador:** download do arquivo esparso; upload em pedaços de 4 MB que o nginx lê inteiros antes de
  responder (repasse para `/nm/sink`).
- **Portas:** os contadores e o reset são os mesmos do rodapé e da seção "Port status" da interface do roteador
  (`/etc/wanlink.base` e `/etc/wanlink/base.ethX`).
