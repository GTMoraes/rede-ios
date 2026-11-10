import Foundation
import Observation

@MainActor
@Observable
final class Estado {
    var enderecos: Enderecos?
    var modo: Modo = .procurando
    var dados: RespostaRoteador?
    var erro: String?
    var atualizadoEm: Date?
    var carregando = false
    /// A tela de velocidade pausa a atualização automática enquanto mede.
    var pausado = false
    /// Nomes dados no app (MAC → nome). Ficam só no iPhone.
    var nomes: [String: String] = (UserDefaults.standard.dictionary(forKey: Chave.nomes) as? [String: String]) ?? [:]

    /// Esquece onde estão o roteador e o GT-SRV (a rede pode ter mudado).
    func redescobrir() {
        enderecos = nil
    }

    func atualizar() async {
        if carregando { return }
        if Config.token.isEmpty {
            modo = .semToken
            erro = nil
            return
        }
        carregando = true
        defer { carregando = false }
        if enderecos == nil || enderecos?.roteador == nil {
            if dados == nil { modo = .procurando }
            let e = await Rede.descobrir()
            enderecos = e
            modo = e.modo
        }
        guard let base = enderecos?.roteador else {
            erro = modo == .soServidor
                ? "O GT-SRV respondeu, mas o roteador não. Confira se a API do roteador está instalada."
                : "Não achei o roteador nem o GT-SRV. Em casa: Wi-Fi ligado. Fora: Tailscale ligada."
            return
        }
        do {
            let r = Rede.pedido(Rede.url(base, "/api?a=all"))
            dados = try await Rede.json(RespostaRoteador.self, r)
            atualizadoEm = Date()
            erro = nil
        } catch {
            erro = error.localizedDescription
            enderecos = nil  // procura de novo na próxima vez
        }
    }

    // MARK: ações

    func zerar(dev: String) async {
        guard let base = enderecos?.roteador else { return }
        do {
            _ = try await Rede.dados(Rede.pedido(Rede.url(base, "/api?a=reset&dev=\(dev)")))
            await atualizar()
        } catch {
            erro = error.localizedDescription
        }
    }

    func reiniciar() async throws {
        guard let base = enderecos?.roteador else { throw ErroApp("Roteador não encontrado.") }
        _ = try await Rede.dados(Rede.pedido(Rede.url(base, "/api?a=reboot"), metodo: "POST"))
        dados = nil
        enderecos = nil
    }

    func testeInternetRoteador() async throws -> ResultadoRemoto {
        guard let base = enderecos?.roteador else { throw ErroApp("Roteador não encontrado.") }
        return try await Rede.json(ResultadoRemoto.self,
                                   Rede.pedido(Rede.url(base, "/api?a=wantest&secs=8"), timeout: 75))
    }

    func testeInternetServidor() async throws -> ResultadoRemoto {
        guard let srv = enderecos?.servidor else { throw ErroApp("GT-SRV não encontrado.") }
        return try await Rede.json(ResultadoRemoto.self,
                                   Rede.pedido(Rede.url(srv, "/wantest?secs=8"), timeout: 75, token: false))
    }

    func renomear(mac: String, para nome: String) {
        let n = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { nomes[mac] = nil } else { nomes[mac] = n }
        UserDefaults.standard.set(nomes, forKey: Chave.nomes)
    }

    // MARK: dados derivados

    var wan: WanStatus? { dados?.wan }

    var ipPublico: String? { dados?.wan?.ipv4?.first?.address }

    var prefixoIPv6: String? {
        guard let p = dados?.wan6?.prefixos?.first else { return nil }
        if let m = p.mask { return "\(p.address)/\(m)" }
        return p.address
    }

    func porta(dev: String) -> Porta? {
        dados?.ports.first { $0.dev == dev }
    }

    /// Junta Wi-Fi, tabela da bridge, DHCP, ARP e trafficd numa lista de aparelhos.
    var aparelhos: [Aparelho] {
        guard let d = dados else { return [] }
        var ipPorMac: [String: String] = [:]
        var nomePorMac: [String: String] = [:]
        for a in d.arp { ipPorMac[a.mac] = a.ip }
        for l in d.leases {
            ipPorMac[l.mac] = l.ip
            nomePorMac[l.mac] = l.name
        }
        var traffic: [String: DispositivoTraffic] = [:]
        for (k, v) in d.devices ?? [:] { traffic[k.lowercased()] = v }

        func nomeRede(_ mac: String) -> String {
            let semPontos = mac.replacingOccurrences(of: ":", with: "")
            for candidato in [nomePorMac[mac], traffic[mac]?.hostname] {
                if let c = candidato, !c.isEmpty, c.lowercased() != semPontos { return c }
            }
            return ""
        }

        func montar(_ mac: String, banda: Banda) -> Aparelho {
            let t = traffic[mac]
            let rede = nomeRede(mac)
            let ip = ipPorMac[mac] ?? t?.ip_list?.first?.ip
            var a = Aparelho(mac: mac, nome: nomes[mac] ?? (rede.isEmpty ? "Sem nome" : rede),
                             nomeRede: rede, ip: ip, banda: banda)
            a.baixando = t?.ip_list?.first?.tx_rate
            a.enviando = t?.ip_list?.first?.rx_rate
            if let o = t?.online_timer, banda == .cabo { a.conectado = Fmt.duracao(o) }
            return a
        }

        var lista: [Aparelho] = []
        var vistos = Set<String>()
        for (banda, clientes) in [(Banda.g5, d.wifi.g5), (Banda.g2, d.wifi.g2)] {
            for c in clientes where !vistos.contains(c.mac) {
                vistos.insert(c.mac)
                var a = montar(c.mac, banda: banda)
                a.rssi = c.rssi
                a.taxaTx = c.tx
                a.taxaRx = c.rx
                a.conectado = c.assoc
                a.modo = c.mode
                lista.append(a)
            }
        }
        for f in d.fdb where f.dev.hasPrefix("eth") && !vistos.contains(f.mac) {
            vistos.insert(f.mac)
            var a = montar(f.mac, banda: .cabo)
            if let p = porta(dev: f.dev) {
                a.porta = p.label.isEmpty ? p.port : "\(p.port) · \(p.label)"
            } else {
                a.porta = f.dev
            }
            lista.append(a)
        }
        return lista.sorted {
            if $0.nome == "Sem nome" && $1.nome != "Sem nome" { return false }
            if $1.nome == "Sem nome" && $0.nome != "Sem nome" { return true }
            return $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending
        }
    }
}
