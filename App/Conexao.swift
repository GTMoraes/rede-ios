import Foundation

/// Chaves dos ajustes (as mesmas do @AppStorage da tela de Ajustes).
enum Chave {
    static let token = "token"
    static let roteador = "roteador"
    static let servidorLAN = "servidorLAN"
    static let servidorTS = "servidorTS"
    static let nomes = "nomesAparelhos"
    static let tokenPush = "tokenPush"
}

enum Padrao {
    static let roteador = "10.0.0.1:8077"
    static let servidorLAN = "10.0.0.129:9092"
    static let servidorTS = "100.91.24.1:9092"
}

enum Config {
    private static var d: UserDefaults { .standard }

    static var token: String { (d.string(forKey: Chave.token) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var roteador: String { host(d.string(forKey: Chave.roteador), Padrao.roteador) }
    static var servidorLAN: String { host(d.string(forKey: Chave.servidorLAN), Padrao.servidorLAN) }
    static var servidorTS: String { host(d.string(forKey: Chave.servidorTS), Padrao.servidorTS) }

    /// Aceita "10.0.0.1:8077", "http://10.0.0.1:8077/" etc.
    private static func host(_ s: String?, _ padrao: String) -> String {
        var h = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("http://") { h.removeFirst(7) }
        while h.hasSuffix("/") { h.removeLast() }
        return h.isEmpty ? padrao : h
    }
}

enum Modo: Equatable {
    case procurando
    case casa
    case fora
    case soServidor
    case semConexao
    case semToken

    var texto: String {
        switch self {
        case .procurando: return "Procurando…"
        case .casa: return "Em casa"
        case .fora: return "Fora · Tailscale"
        case .soServidor: return "Só o GT-SRV responde"
        case .semConexao: return "Sem conexão"
        case .semToken: return "Falta o token"
        }
    }

    var icone: String {
        switch self {
        case .procurando: return "ellipsis"
        case .casa: return "house.fill"
        case .fora: return "network"
        case .soServidor: return "server.rack"
        case .semConexao: return "wifi.slash"
        case .semToken: return "key"
        }
    }
}

/// Onde estão o roteador e o GT-SRV agora.
struct Enderecos {
    /// Base da API do roteador (…/nm). Em casa é o próprio roteador; fora, a ponte do GT-SRV.
    var roteador: URL?
    /// Base do servidor do GT-SRV.
    var servidor: URL?
    var modo: Modo
}

private struct ErroAPI: Decodable {
    let error: String
}

enum Rede {
    static let sessao: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func url(_ base: URL, _ caminho: String) -> URL {
        URL(string: base.absoluteString + caminho)!
    }

    static func pedido(_ url: URL, metodo: String = "GET", timeout: TimeInterval = 12,
                       token: Bool = true) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = metodo
        if token { r.setValue(Config.token, forHTTPHeaderField: "X-NM-Token") }
        return r
    }

    static func dados(_ r: URLRequest) async throws -> Data {
        let (d, resp) = try await sessao.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw ErroApp("Resposta inválida.") }
        if h.statusCode == 403 { throw ErroApp("O roteador recusou o token. Confira em Ajustes.") }
        // a API devolve {"error": "..."}; frases vão direto para a tela
        if let e = try? JSONDecoder().decode(ErroAPI.self, from: d), e.error.count > 12 {
            throw ErroApp(e.error)
        }
        if h.statusCode == 409 { throw ErroApp("Já há um teste em andamento. Tente de novo em instantes.") }
        guard (200..<300).contains(h.statusCode) else { throw ErroApp("O servidor respondeu HTTP \(h.statusCode).") }
        return d
    }

    static func json<T: Decodable>(_ tipo: T.Type, _ r: URLRequest) async throws -> T {
        let d = try await dados(r)
        do {
            return try JSONDecoder().decode(T.self, from: d)
        } catch {
            throw ErroApp("Resposta em formato inesperado (\(error.localizedDescription)).")
        }
    }

    /// Por que a última procura falhou (mensagem do iOS), para aparecer na tela.
    static var ultimaFalha: String?

    private static func responde(_ url: URL, app: String, timeout: TimeInterval) async -> Bool {
        let r = pedido(url, timeout: timeout, token: false)
        do {
            let id = try await json(Identidade.self, r)
            return id.app == app
        } catch {
            ultimaFalha = "\(url.host ?? ""): \(error.localizedDescription)"
            return false
        }
    }

    /// Em casa o roteador responde direto. Fora, o app passa pela ponte do GT-SRV (Tailscale).
    /// O token só é enviado depois que o endereço se identifica como o nosso roteador.
    static func descobrir() async -> Enderecos {
        let rot = URL(string: "http://\(Config.roteador)/nm")!
        let lan = URL(string: "http://\(Config.servidorLAN)")!
        let ts = URL(string: "http://\(Config.servidorTS)")!

        if await responde(url(rot, "/id"), app: "netmon", timeout: 2) {
            let srv = await responde(url(lan, "/id"), app: "rede-srv", timeout: 2)
            return Enderecos(roteador: rot, servidor: srv ? lan : nil, modo: .casa)
        }
        let ponte = url(ts, "/router/nm")
        if await responde(url(ponte, "/id"), app: "netmon", timeout: 5) {
            return Enderecos(roteador: ponte, servidor: ts, modo: .fora)
        }
        if await responde(url(ts, "/id"), app: "rede-srv", timeout: 3) {
            return Enderecos(roteador: nil, servidor: ts, modo: .soServidor)
        }
        return Enderecos(roteador: nil, servidor: nil, modo: .semConexao)
    }
}
