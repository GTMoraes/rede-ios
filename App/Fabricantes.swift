import Foundation

/// Consulta de MAC: de quem é o prefixo (OUI) e se o endereço é aleatório.
/// A tabela (App/oui.txt, "AABBCC<tab>Fabricante") é baixada pelo workflow a cada build, da lista do Wireshark
/// (ou da IEEE, se ela falhar). Se o prefixo não estiver nela, o app pergunta ao api.macvendors.com e guarda a resposta.
enum Fabricantes {
    private static let tabela: [String: String] = {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "txt"),
              let texto = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t: [String: String] = [:]
        t.reserveCapacity(40000)
        for linha in texto.split(separator: "\n") {
            guard let tab = linha.firstIndex(of: "\t") else { continue }
            t[String(linha[..<tab])] = String(linha[linha.index(after: tab)...])
        }
        return t
    }()

    /// Carrega a tabela fora da tela (chamar ao abrir o app).
    static func preparar() {
        DispatchQueue.global(qos: .utility).async { _ = tabela.count }
    }

    /// Só os dígitos hexadecimais, em maiúsculas.
    static func hex(_ texto: String) -> String {
        String(texto.uppercased().filter { "0123456789ABCDEF".contains($0) })
    }

    /// Parece um MAC ou um prefixo de MAC (pelo menos 6 dígitos hexadecimais, só com separadores de MAC).
    static func pareceMAC(_ texto: String) -> Bool {
        let t = texto.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, t.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" || $0 == "." }) else { return false }
        return hex(t).count >= 6
    }

    static func prefixo(_ mac: String) -> String? {
        let h = hex(mac)
        return h.count >= 6 ? String(h.prefix(6)) : nil
    }

    /// Bit "administrado localmente" ligado: endereço inventado pelo próprio aparelho (MAC privado/aleatório
    /// de celular e notebook, ou de máquina virtual), sem fabricante para consultar.
    static func aleatorio(_ mac: String) -> Bool {
        guard let p = prefixo(mac), let b = UInt8(p.prefix(2), radix: 16) else { return false }
        return b & 0x02 != 0
    }

    static func local(_ mac: String) -> String? {
        guard let p = prefixo(mac) else { return nil }
        return tabela[p]
    }

    /// Para mostrar na lista: o fabricante, ou "MAC aleatório".
    static func descricao(_ mac: String) -> String? {
        if aleatorio(mac) { return "MAC aleatório (privado)" }
        return local(mac)
    }

    /// Pergunta ao api.macvendors.com (gratuito, sem chave, 1 consulta por segundo). Guarda a resposta.
    static func online(_ mac: String) async -> String? {
        guard let p = prefixo(mac), !aleatorio(mac) else { return nil }
        let chave = "oui." + p
        if let salvo = UserDefaults.standard.string(forKey: chave) { return salvo.isEmpty ? nil : salvo }
        guard let url = URL(string: "https://api.macvendors.com/\(p)") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.setValue("Rede-iOS", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              let h = resp as? HTTPURLResponse else { return nil }
        if h.statusCode == 404 {
            UserDefaults.standard.set("", forKey: chave)
            return nil
        }
        guard h.statusCode == 200, let nome = String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !nome.isEmpty else { return nil }
        UserDefaults.standard.set(nome, forKey: chave)
        return nome
    }

    /// "AA:BB:CC" a partir de qualquer texto com o prefixo.
    static func prefixoFormatado(_ mac: String) -> String {
        guard let p = prefixo(mac) else { return mac }
        let c = Array(p)
        return "\(c[0])\(c[1]):\(c[2])\(c[3]):\(c[4])\(c[5])"
    }
}
