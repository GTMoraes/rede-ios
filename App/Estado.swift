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

    /// Ações do controle de acesso ao Wi-Fi. Devolvem a mensagem de erro, ou nil se deu certo.
    private func acaoAcesso(_ consulta: String) async -> String? {
        guard let base = enderecos?.roteador else { return "Roteador não encontrado." }
        do {
            _ = try await Rede.dados(Rede.pedido(Rede.url(base, "/api?\(consulta)"), metodo: "POST", timeout: 20))
            await atualizar()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Bloqueia (ou libera). No modo "só autorizados", bloquear = tirar da lista de autorizados.
    func bloquear(mac: String, _ bloquear: Bool = true) async -> String? {
        await acaoAcesso("a=\(bloquear ? "block" : "unblock")&mac=\(mac)")
    }

    /// Nome no roteador (o mesmo da tela de IP fixo e do app Mi WiFi). Vazio volta ao nome que o aparelho informa.
    func salvarNome(mac: String, nome: String) async -> String? {
        let n = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        let erro = await acaoAcesso("a=name&mac=\(mac)&name=\(Estado.codificar(n))")
        if erro == nil, nomes[mac] != nil { renomear(mac: mac, para: "") }  // o nome antigo, só do app, sai
        return erro
    }

    func fixarIP(mac: String, ip: String) async -> String? {
        await acaoAcesso("a=static_set&mac=\(mac)&ip=\(Estado.codificar(ip))")
    }

    func desafixarIP(mac: String) async -> String? {
        await acaoAcesso("a=static_del&mac=\(mac)")
    }

    /// Codifica para a URL: só letras e números ASCII passam; o resto (espaço, +, acentos) vira %XX.
    static func codificar(_ s: String) -> String {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
    }

    /// Autoriza todos os aparelhos conectados agora no Wi-Fi.
    func autorizarConectados() async -> String? {
        await acaoAcesso("a=snapshot")
    }

    func definirSoAutorizados(_ sim: Bool) async -> String? {
        await acaoAcesso("a=mode&m=\(sim ? "allow" : "deny")")
    }

    var acl: ACL? { dados?.acl }

    /// Conectados no Wi-Fi agora que ainda não estão na lista de autorizados.
    var naoAutorizados: [Aparelho] {
        guard let acl else { return [] }
        let autorizados = Set(acl.allow)
        return aparelhos.filter { ($0.banda == .g5 || $0.banda == .g2) && !autorizados.contains($0.mac) }
    }

    /// Conectados no Wi-Fi agora que ficariam de fora se o modo "só autorizados" fosse ligado com a lista atual.
    var ficariamDeFora: [Aparelho] {
        guard let acl else { return [] }
        let autorizados = Set(acl.allow)
        return aparelhos.filter { ($0.banda == .g5 || $0.banda == .g2) && !$0.euMesmo && !autorizados.contains($0.mac) }
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

        var fixoPorMac: [String: String] = [:]
        for f in d.fixos { fixoPorMac[f.mac.lowercased()] = f.ip }

        /// Nome que o aparelho informa (DHCP, banco da Xiaomi ou trafficd), sem o dado pelo usuário.
        func nomeRede(_ mac: String) -> String {
            let semPontos = mac.replacingOccurrences(of: ":", with: "")
            for candidato in [nomePorMac[mac], d.names[mac]?.oname, traffic[mac]?.hostname] {
                if let c = candidato, !c.isEmpty, c.lowercased() != semPontos { return c }
            }
            return ""
        }

        /// Nome dado pelo usuário (no app, antigo, ou no roteador).
        func apelido(_ mac: String) -> String? {
            if let n = nomes[mac], !n.isEmpty { return n }
            if let n = d.names[mac]?.nick, !n.isEmpty { return n }
            return nil
        }

        func montar(_ mac: String, banda: Banda) -> Aparelho {
            let t = traffic[mac]
            let rede = nomeRede(mac)
            let ip = ipPorMac[mac] ?? t?.ip_list?.first?.ip
            var a = Aparelho(mac: mac, nome: apelido(mac) ?? (rede.isEmpty ? "Sem nome" : rede),
                             nomeRede: rede, ip: ip, banda: banda)
            a.ipFixo = fixoPorMac[mac]
            a.baixando = t?.ip_list?.first?.tx_rate
            a.enviando = t?.ip_list?.first?.rx_rate
            if let o = t?.online_timer, banda == .cabo { a.conectado = Fmt.duracao(o) }
            return a
        }

        var lista: [Aparelho] = []
        let eu = d.me
        // bloqueado que ainda aparece conectado (o chip leva um instante para derrubar) não entra nas bandas
        var vistos = d.acl.soAutorizados ? Set<String>() : Set(d.acl.deny)
        var conectados = Set<String>()
        for (banda, clientes) in [(Banda.g5, d.wifi.g5), (Banda.g2, d.wifi.g2)] {
            for c in clientes where !vistos.contains(c.mac) {
                vistos.insert(c.mac)
                var a = montar(c.mac, banda: banda)
                a.rssi = c.rssi
                a.taxaTx = c.tx
                a.taxaRx = c.rx
                a.conectado = c.assoc
                a.modo = c.mode
                a.online = true
                a.euMesmo = c.mac == eu
                conectados.insert(c.mac)
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
            a.online = true
            a.dev = f.dev
            lista.append(a)
        }
        // aba Controle: a lista que vale agora (bloqueados ou autorizados), conectados ou não
        for mac in d.acl.ativa {
            var a = montar(mac, banda: .controle)
            a.online = conectados.contains(mac)
            a.euMesmo = mac == eu
            lista.append(a)
        }
        return lista.sorted {
            if $0.nome == "Sem nome" && $1.nome != "Sem nome" { return false }
            if $1.nome == "Sem nome" && $0.nome != "Sem nome" { return true }
            return $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending
        }
    }
}
