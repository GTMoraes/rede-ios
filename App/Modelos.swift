import Foundation

// Resposta de /nm/api?a=all (roteador). Partes vindas do ubus são decodificadas com tolerância:
// se o formato mudar, o resto da tela continua funcionando.

struct RespostaRoteador: Decodable {
    let sys: Sistema
    let wan: WanStatus?
    let wan6: WanStatus?
    let ports: [Porta]
    let wifi: ListasWifi
    let fdb: [EntradaFDB]
    let leases: [Concessao]
    let arp: [EntradaARP]
    let devices: [String: DispositivoTraffic]?
    /// Controle de acesso ao Wi-Fi: modo ("deny" = lista de bloqueio, "allow" = só autorizados) e as duas listas.
    let acl: ACL
    /// MAC de quem fez o pedido (o próprio iPhone, quando está no Wi-Fi de casa).
    let me: String?
    /// Nomes do banco da Xiaomi (MAC → nome dado pelo usuário e nome que o aparelho informa).
    let names: [String: NomeXiaomi]
    /// IPs fixos (a lista da tela "DHCP static IP assignment").
    let fixos: [IPFixo]

    enum CodingKeys: String, CodingKey {
        case sys, wan, wan6, ports, wifi, fdb, leases, arp, devices, acl, blocked, me, names
        case fixos = "static"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sys = try c.decode(Sistema.self, forKey: .sys)
        ports = try c.decode([Porta].self, forKey: .ports)
        wifi = (try? c.decode(ListasWifi.self, forKey: .wifi)) ?? ListasWifi(g5: [], g2: [])
        fdb = (try? c.decode([EntradaFDB].self, forKey: .fdb)) ?? []
        leases = (try? c.decode([Concessao].self, forKey: .leases)) ?? []
        arp = (try? c.decode([EntradaARP].self, forKey: .arp)) ?? []
        wan = try? c.decode(WanStatus.self, forKey: .wan)
        wan6 = try? c.decode(WanStatus.self, forKey: .wan6)
        devices = try? c.decode([String: DispositivoTraffic].self, forKey: .devices)
        if let a = try? c.decode(ACL.self, forKey: .acl) {
            acl = a
        } else {
            let b = (try? c.decode([String].self, forKey: .blocked)) ?? []
            acl = ACL(mode: "deny", allow: [], deny: b)
        }
        let m = (try? c.decode(String.self, forKey: .me)) ?? ""
        me = m.isEmpty ? nil : m.lowercased()
        names = (try? c.decode([String: NomeXiaomi].self, forKey: .names)) ?? [:]
        fixos = (try? c.decode([IPFixo].self, forKey: .fixos)) ?? []
    }
}

struct NomeXiaomi: Decodable {
    let nick: String
    let oname: String
}

struct IPFixo: Decodable {
    let mac: String
    let ip: String
}

struct ACL: Decodable {
    /// "deny" = lista de bloqueio, "allow" = só autorizados, "approve" = aprovação (quarentena).
    let mode: String
    let allow: [String]
    let deny: [String]
    /// Conectados no Wi-Fi esperando aprovação (só no modo aprovação).
    var pending: [Pendente]? = nil
    var soAutorizados: Bool { mode == "allow" }
    var aprovacao: Bool { mode == "approve" }
    var pendentes: [Pendente] { pending ?? [] }

    var nomeDoModo: String {
        switch mode {
        case "allow": return "Só autorizados"
        case "approve": return "Aprovação"
        default: return "Lista de bloqueio"
        }
    }
}

struct Pendente: Decodable {
    let mac: String
    let band: String
}

/// Situação de um aparelho na aba Controle.
enum Situacao: Int {
    case pendente = 0
    case autorizado = 1
    case bloqueado = 2

    var texto: String {
        switch self {
        case .pendente: return "aguardando aprovação"
        case .autorizado: return "autorizado"
        case .bloqueado: return "bloqueado"
        }
    }
}



struct Sistema: Decodable {
    let host: String
    let uptime: Double
    let load: String
    let mem_total_kb: Double?
    let mem_avail_kb: Double?
}

struct EnderecoIP: Decodable {
    let address: String
    let mask: Int?
}

struct WanStatus: Decodable {
    let up: Bool?
    let uptime: Double?
    let proto: String?
    let ipv4: [EnderecoIP]?
    let ipv6: [EnderecoIP]?
    let prefixos: [EnderecoIP]?
    let dns: [String]?

    enum CodingKeys: String, CodingKey {
        case up, uptime, proto
        case ipv4 = "ipv4-address"
        case ipv6 = "ipv6-address"
        case prefixos = "ipv6-prefix"
        case dns = "dns-server"
    }
}

struct Porta: Decodable, Identifiable {
    let port: String
    let dev: String
    let label: String
    let up: Bool
    let speed: Int?
    let duplex: String?
    let drops: Int
    let crc: Int
    let since: String?
    let rx_bytes: Double?
    let tx_bytes: Double?
    var id: String { dev }
}

struct ListasWifi: Decodable {
    let g5: [ClienteWifi]
    let g2: [ClienteWifi]
    enum CodingKeys: String, CodingKey {
        case g5 = "5g"
        case g2 = "2g"
    }
    init(g5: [ClienteWifi], g2: [ClienteWifi]) {
        self.g5 = g5
        self.g2 = g2
    }
}

struct ClienteWifi: Decodable {
    let mac: String
    let chan: Int?
    let tx: Int?
    let rx: Int?
    let rssi: Int?
    let assoc: String?
    let mode: String?
}

struct EntradaFDB: Decodable {
    let mac: String
    let dev: String
    let age: Double?
}

struct Concessao: Decodable {
    let mac: String
    let ip: String
    let name: String
}

struct EntradaARP: Decodable {
    let ip: String
    let mac: String
    let dev: String
}

struct DispositivoTraffic: Decodable {
    let hw: String?
    let ifname: String?
    let hostname: String?
    let online_timer: Double?
    let ip_list: [IPTraffic]?
}

struct IPTraffic: Decodable {
    let ip: String?
    let rx_rate: Double?
    let tx_rate: Double?
}

/// Resultado do teste de internet feito pelo roteador ou pelo GT-SRV.
struct ResultadoRemoto: Decodable {
    let down_mbps: Double?
    let up_mbps: Double?
    let ping_ms: Double?
    let error: String?
}

struct Identidade: Decodable {
    let app: String
}

// MARK: - aparelho já combinado (Wi-Fi + tabela da bridge + DHCP + trafficd)

enum Banda: String, CaseIterable, Identifiable {
    case g5 = "5 GHz"
    case g2 = "2,4 GHz"
    case cabo = "Cabo"
    case controle = "Controle"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .g5, .g2: return "wifi"
        case .cabo: return "cable.connector"
        case .controle: return "lock.shield"
        }
    }
    /// Dá para bloquear no Wi-Fi (os de cabo e os do roteador IoT, não).
    var bloqueavel: Bool { self == .g5 || self == .g2 }
}

struct Aparelho: Identifiable {
    let mac: String
    var id: String { mac }
    var nome: String
    var nomeRede: String
    var ip: String?
    var banda: Banda
    var porta: String?
    /// Interface da porta (eth2, eth3…), para agrupar os aparelhos de cabo por porta.
    var dev: String?
    /// IP fixado no roteador (DHCP estático), se houver.
    var ipFixo: String?
    var rssi: Int?
    var taxaTx: Int?
    var taxaRx: Int?
    var conectado: String?
    var modo: String?
    var baixando: Double?
    var enviando: Double?
    /// Conectado agora (para os itens da aba Controle, que lista também quem está fora do ar).
    var online = false
    /// É o iPhone que está usando o app: não pode ser bloqueado por ele mesmo.
    var euMesmo = false
    /// Na aba Controle: pendente, autorizado ou bloqueado. Nas bandas: só "pendente" (modo aprovação).
    var situacao: Situacao?

    /// 0 a 1, para o símbolo de Wi-Fi.
    var sinal: Double {
        guard let r = rssi else { return 0 }
        if r >= -55 { return 1 }
        if r >= -67 { return 0.66 }
        if r >= -75 { return 0.33 }
        return 0.05
    }
}
