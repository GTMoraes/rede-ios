import SwiftUI

/// Um teste: download, upload e latência, do iPhone até algum lugar, ou feito por outro aparelho.
enum TipoTeste: String, CaseIterable, Identifiable, Codable {
    case celularInternet
    case roteadorInternet
    case servidorInternet
    case celularRoteador
    case celularServidor

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .celularInternet: return "iPhone → Internet"
        case .roteadorInternet: return "Roteador → Internet"
        case .servidorInternet: return "GT-SRV → Internet (cabo)"
        case .celularRoteador: return "iPhone ↔ Roteador"
        case .celularServidor: return "iPhone ↔ GT-SRV"
        }
    }

    var detalhe: String {
        switch self {
        case .celularInternet:
            return "O que você sente no dia a dia: inclui o Wi-Fi (ou o 5G, fora de casa). Servidores da Cloudflare."
        case .roteadorInternet:
            return "Medido pelo próprio roteador, sem Wi-Fi no caminho. O processador dele limita: valores perto de 250 Mb/s podem ser o teto do roteador, não da TIM."
        case .servidorInternet:
            return "Medido pelo GT-SRV, ligado por cabo. É o melhor retrato do link da TIM."
        case .celularRoteador:
            return "Só o Wi-Fi: do iPhone até o roteador. Funciona só em casa."
        case .celularServidor:
            return "Wi-Fi + cabo até o GT-SRV (em casa), ou o caminho pela Tailscale (fora)."
        }
    }

    var icone: String {
        switch self {
        case .celularInternet: return "iphone.gen3"
        case .roteadorInternet: return "wifi.router"
        case .servidorInternet: return "server.rack"
        case .celularRoteador: return "wifi"
        case .celularServidor: return "externaldrive.connected.to.line.below"
        }
    }

    /// Medido no iPhone (true) ou pedido a outro aparelho (false).
    var noIphone: Bool {
        switch self {
        case .roteadorInternet, .servidorInternet: return false
        default: return true
        }
    }
}

struct Resultado: Codable {
    var down: Double?
    var up: Double?
    var ping: Double?
    var quando: Date
}

struct VelocidadeView: View {
    @Environment(Estado.self) private var estado
    @AppStorage("resultados") private var guardados: Data = Data()
    @State private var resultados: [String: Resultado] = [:]
    @State private var rodando: TipoTeste?
    /// Cartão do topo: o teste em andamento e, depois, o último medido (com o resultado).
    @State private var destaque: TipoTeste?
    @State private var fase = ""
    @State private var aoVivo: Double = 0
    @State private var erro: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { rolagem in
                ScrollView {
                    GlassEffectContainer(spacing: 14) {
                        VStack(spacing: 14) {
                            Color.clear.frame(height: 0).id("topo")
                            if let destaque {
                                painelDestaque(destaque)
                            }
                            ForEach(TipoTeste.allCases) { t in
                                cartao(t)
                            }
                            dica
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
                // ao começar um teste, sobe para o cartão ao vivo
                .onChange(of: rodando) { _, novo in
                    if novo != nil {
                        withAnimation(.snappy) { rolagem.scrollTo("topo", anchor: .top) }
                    }
                }
            }
            .navigationTitle("Velocidade")
            .telaEscura()
            .onAppear(perform: carregar)
            .alert("Teste", isPresented: Binding(get: { erro != nil }, set: { if !$0 { erro = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(erro ?? "")
            }
        }
    }

    // MARK: partes

    private func painelDestaque(_ t: TipoTeste) -> some View {
        VStack(spacing: 10) {
            Label(t.titulo, systemImage: t.icone)
                .font(.headline)
            if rodando == t {
                if t.noIphone {
                    Text(Fmt.mbps(aoVivo))
                        .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.snappy, value: aoVivo)
                    Text("Mb/s · \(fase)").font(.subheadline).foregroundStyle(Tema.texto2)
                } else {
                    ProgressView().controlSize(.large).padding(.vertical, 8)
                    Text(fase).font(.subheadline).foregroundStyle(Tema.texto2)
                }
            } else if let r = resultados[t.rawValue] {
                HStack(alignment: .top) {
                    metrica("Download", Fmt.mbps(r.down), "Mb/s", "arrow.down.circle", grande: true)
                    metrica("Upload", Fmt.mbps(r.up), "Mb/s", "arrow.up.circle", grande: true)
                    metrica("Latência", numeroMs(r.ping), "ms", "timer", grande: true)
                }
                Text("Medido às \(r.quando.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Tema.texto2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .glassEffect(.regular.tint(Tema.acento.opacity(0.25)), in: .rect(cornerRadius: 28))
    }

    private func cartao(_ t: TipoTeste) -> some View {
        let r = resultados[t.rawValue]
        let indisponivel = motivoIndisponivel(t)
        return Cartao(titulo: t.titulo, icone: t.icone) {
            Text(t.detalhe).font(.caption).foregroundStyle(Tema.texto2)
            HStack(alignment: .top) {
                metrica("Download", Fmt.mbps(r?.down), "Mb/s", "arrow.down.circle")
                metrica("Upload", Fmt.mbps(r?.up), "Mb/s", "arrow.up.circle")
                metrica("Latência", numeroMs(r?.ping), "ms", "timer")
            }
            if let r {
                Text("Medido \(r.quando.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(Tema.texto2)
            }
            if let indisponivel {
                Text(indisponivel).font(.caption).foregroundStyle(Tema.laranja)
            }
            Button {
                Task { await rodar(t) }
            } label: {
                Label(rodando == t ? "Medindo…" : "Medir", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(rodando != nil || indisponivel != nil)
        }
    }

    private func metrica(_ rotulo: String, _ valor: String, _ unidade: String, _ icone: String,
                         grande: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(valor)
                .font(grande ? Font.title.weight(.bold).monospacedDigit() : Font.title3.weight(.semibold).monospacedDigit())
            Text(unidade).font(.caption2).foregroundStyle(Tema.texto2)
            Label(rotulo, systemImage: icone).font(.caption2).foregroundStyle(Tema.texto2)
        }
        .frame(maxWidth: .infinity)
    }

    private func numeroMs(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f", v)
    }

    private var dica: some View {
        Cartao(titulo: "Como ler", icone: "lightbulb") {
            Text("Compare \"iPhone → Internet\" com \"GT-SRV → Internet\": se o iPhone fica bem abaixo, o gargalo é o Wi-Fi; se os dois ficam baixos, é a internet. \"iPhone ↔ Roteador\" mostra o limite do Wi-Fi de onde você está.")
                .font(.caption)
                .foregroundStyle(Tema.texto2)
        }
    }

    private func motivoIndisponivel(_ t: TipoTeste) -> String? {
        let e = estado.enderecos
        switch t {
        case .celularInternet:
            return nil
        case .roteadorInternet:
            return e?.roteador == nil ? "Roteador não encontrado." : nil
        case .servidorInternet, .celularServidor:
            return e?.servidor == nil ? "GT-SRV não encontrado." : nil
        case .celularRoteador:
            if e?.modo == .fora { return "Só em casa (fora, o caminho seria a Tailscale, não o Wi-Fi)." }
            return e?.modo == .casa ? nil : "Roteador não encontrado."
        }
    }

    // MARK: medição

    private func rodar(_ t: TipoTeste) async {
        destaque = t
        rodando = t
        aoVivo = 0
        estado.pausado = true
        defer {
            rodando = nil
            estado.pausado = false
        }
        do {
            var r = Resultado(quando: Date())
            if t.noIphone {
                guard let alvo = alvo(t) else { throw ErroApp("Destino não encontrado.") }
                fase = "latência"
                r.ping = await Latencia.medir(alvo.ping)
                fase = "download"
                aoVivo = 0
                r.down = try await Medidor(tipo: .download, fluxos: alvo.fluxos, pedido: alvo.download)
                    .medir(segundos: 8) { aoVivo = $0 }
                fase = "upload"
                aoVivo = 0
                r.up = try await Medidor(tipo: .upload, fluxos: alvo.fluxos, pedido: alvo.upload)
                    .medir(segundos: 8) { aoVivo = $0 }
            } else {
                fase = "medindo (uns 20 s)…"
                let x: ResultadoRemoto
                if t == .roteadorInternet {
                    x = try await estado.testeInternetRoteador()
                } else {
                    x = try await estado.testeInternetServidor()
                }
                if let e = x.error { throw ErroApp(e) }
                r.down = x.down_mbps
                r.up = x.up_mbps
                r.ping = x.ping_ms
            }
            r.quando = Date()
            resultados[t.rawValue] = r
            salvar()
        } catch {
            erro = error.localizedDescription
            if resultados[t.rawValue] == nil { destaque = nil }
        }
    }

    private struct Alvo {
        var download: () -> URLRequest
        var upload: () -> URLRequest
        var ping: () -> URLRequest
        var fluxos: Int
    }

    private func alvo(_ t: TipoTeste) -> Alvo? {
        switch t {
        case .celularInternet:
            let cf = "https://speed.cloudflare.com"
            return Alvo(
                download: { Rede.pedido(URL(string: "\(cf)/__down?bytes=25000000")!, timeout: 20, token: false) },
                upload: {
                    var r = Rede.pedido(URL(string: "\(cf)/__up")!, metodo: "POST", timeout: 20, token: false)
                    r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    return r
                },
                ping: { Rede.pedido(URL(string: "\(cf)/__down?bytes=0")!, timeout: 5, token: false) },
                fluxos: 6)
        case .celularRoteador:
            guard let base = estado.enderecos?.roteador else { return nil }
            return Alvo(
                download: { Rede.pedido(Rede.url(base, "/dl"), timeout: 20) },
                upload: { Rede.pedido(Rede.url(base, "/up"), metodo: "POST", timeout: 20) },
                ping: { Rede.pedido(Rede.url(base, "/id"), timeout: 5, token: false) },
                fluxos: 4)
        case .celularServidor:
            guard let srv = estado.enderecos?.servidor else { return nil }
            return Alvo(
                download: { Rede.pedido(Rede.url(srv, "/dl?bytes=200000000"), timeout: 20, token: false) },
                upload: { Rede.pedido(Rede.url(srv, "/up"), metodo: "POST", timeout: 20, token: false) },
                ping: { Rede.pedido(Rede.url(srv, "/id"), timeout: 5, token: false) },
                fluxos: 4)
        default:
            return nil
        }
    }

    // MARK: últimos resultados (ficam no iPhone)

    private func carregar() {
        if let r = try? JSONDecoder().decode([String: Resultado].self, from: guardados) {
            resultados = r
        }
    }

    private func salvar() {
        if let d = try? JSONEncoder().encode(resultados) { guardados = d }
    }
}
