import SwiftUI

struct PainelView: View {
    @Environment(Estado.self) private var estado
    @State private var confirmar: Confirmacao?
    @State private var aviso: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 16) {
                        cabecalho
                        if let erro = estado.erro {
                            Cartao(titulo: "Atenção", icone: "exclamationmark.triangle") {
                                Text(erro).font(.subheadline).foregroundStyle(Tema.texto2)
                            }
                        }
                        if estado.dados != nil {
                            internet
                            portas
                            resumoAparelhos
                            roteador
                            BotaoPrincipal(titulo: "Reiniciar o roteador", icone: "power",
                                           cor: Tema.vermelho, desativado: estado.enderecos?.roteador == nil) {
                                confirmar = Confirmacao(
                                    titulo: "Reiniciar o roteador?",
                                    mensagem: "A internet e o Wi-Fi caem por uns 2 minutos.",
                                    botao: "Reiniciar") {
                                        Task { await reiniciar() }
                                    }
                            }
                        } else if estado.modo == .semToken {
                            semToken
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .refreshable {
                estado.redescobrir()
                await estado.atualizar()
            }
            .navigationTitle("Rede")
            .telaEscura()
            .confirmar($confirmar)
            .alert("Roteador", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(aviso ?? "")
            }
        }
    }

    private func reiniciar() async {
        do {
            try await estado.reiniciar()
            aviso = "Reiniciando. Volta em cerca de 2 minutos."
        } catch {
            aviso = error.localizedDescription
        }
    }

    // MARK: partes

    private var cabecalho: some View {
        HStack(spacing: 10) {
            Image(systemName: estado.modo.icone)
            Text(estado.modo.texto).font(.subheadline.weight(.semibold))
            Spacer()
            if estado.carregando {
                ProgressView().controlSize(.small)
            } else if let t = estado.atualizadoEm {
                Text(t, style: .time).font(.caption).foregroundStyle(Tema.texto2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private var semToken: some View {
        Cartao(titulo: "Configure o app", icone: "key") {
            Text("Em Ajustes, cole o token do roteador (aparece no fim da instalação da API, ou com `cat /etc/netmon/token` no SSH).")
                .font(.subheadline)
                .foregroundStyle(Tema.texto2)
        }
    }

    private var internet: some View {
        let wan = estado.wan
        let online = wan?.up == true
        return Cartao(titulo: "Internet (PPPoE)", icone: "globe") {
            HStack(spacing: 8) {
                Bolinha(cor: online ? Tema.verde : Tema.vermelho)
                Text(online ? "Conectada" : "Desconectada").font(.title3.weight(.semibold))
                Spacer()
                if online, let up = wan?.uptime {
                    Text("há \(Fmt.duracao(up))").font(.subheadline).foregroundStyle(Tema.texto2)
                }
            }
            LinhaInfo(rotulo: "IP público", valor: estado.ipPublico ?? "—")
            LinhaInfo(rotulo: "Prefixo IPv6", valor: estado.prefixoIPv6 ?? "—")
            if let dns = wan?.dns, !dns.isEmpty {
                LinhaInfo(rotulo: "DNS", valor: dns.joined(separator: "\n"))
            }
        }
    }

    private var portas: some View {
        Cartao(titulo: "Portas", icone: "cable.connector.horizontal") {
            ForEach(estado.dados?.ports ?? []) { p in
                LinhaPorta(p: p)
                    .contextMenu {
                        Button {
                            Task { await estado.zerar(dev: p.dev) }
                        } label: {
                            Label("Zerar quedas e CRC", systemImage: "arrow.counterclockwise")
                        }
                    }
                if p.id != estado.dados?.ports.last?.id { Divider().opacity(0.4) }
            }
            Text("Toque e segure uma porta para zerar os contadores.")
                .font(.caption)
                .foregroundStyle(Tema.texto2)
        }
    }

    private var resumoAparelhos: some View {
        let lista = estado.aparelhos
        return Cartao(titulo: "Aparelhos conectados", icone: "laptopcomputer.and.iphone") {
            HStack {
                ForEach(Banda.allCases) { b in
                    VStack(spacing: 4) {
                        Text("\(lista.filter { $0.banda == b }.count)")
                            .font(.title2.weight(.bold).monospacedDigit())
                        Label(b.rawValue, systemImage: b.icone)
                            .font(.caption)
                            .foregroundStyle(Tema.texto2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var roteador: some View {
        let s = estado.dados?.sys
        return Cartao(titulo: "Roteador", icone: "wifi.router") {
            LinhaInfo(rotulo: "Ligado há", valor: Fmt.duracao(s?.uptime))
            LinhaInfo(rotulo: "Carga (1, 5, 15 min)", valor: s?.load ?? "—")
            if let t = s?.mem_total_kb, let a = s?.mem_avail_kb {
                LinhaInfo(rotulo: "Memória livre", valor: "\(Fmt.bytes(a * 1024)) de \(Fmt.bytes(t * 1024))")
            }
        }
    }
}

struct LinhaPorta: View {
    let p: Porta

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Bolinha(cor: p.up ? Tema.corVelocidade(p.speed) : .gray)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.label.isEmpty ? p.port : "\(p.port) · \(p.label)")
                    .font(.body.weight(.semibold))
                if p.up {
                    Text("quedas \(p.drops) · CRC \(p.crc)")
                        .font(.caption)
                        .foregroundStyle(p.drops > 0 || p.crc > 0 ? Tema.laranja : Tema.texto2)
                }
            }
            Spacer()
            Text(p.up ? "\(p.speed.map { "\($0)" } ?? "?") Mb/s" : "desligada")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(p.up ? .primary : Tema.texto2)
        }
        .contentShape(Rectangle())
    }
}
