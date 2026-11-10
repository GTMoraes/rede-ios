import SwiftUI
import UIKit

struct AparelhosView: View {
    @Environment(Estado.self) private var estado
    @State private var banda: Banda = .g5
    @State private var renomeando: Aparelho?
    @State private var novoNome = ""
    @State private var busca = ""
    /// Linhas que acabaram de ser arrastadas até o fim: saem da tela enquanto o roteador aplica.
    @State private var saindo = Set<String>()
    @State private var aviso: String?
    @State private var perguntandoLigar = false
    @State private var perguntandoDesligar = false
    @State private var ocupado = false

    var body: some View {
        NavigationStack {
            let lista = filtrados
            List {
                Picker("Banda", selection: $banda) {
                    ForEach(Banda.allCases) { b in
                        Text(b.rawValue).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

                if banda == .controle {
                    controle
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                Text(rodape(lista.count))
                    .font(.caption)
                    .foregroundStyle(Tema.texto2)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))

                ForEach(lista) { a in
                    LinhaAparelho(a: a)
                        .offset(x: saindo.contains(a.mac) ? -700 : 0)
                        .opacity(saindo.contains(a.mac) ? 0 : 1)
                        // arrastar até a metade mostra o botão; até o fim, executa
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let acao = acaoDoGesto(a) {
                                Button {
                                    alternar(a, bloquear: acao.bloquear)
                                } label: {
                                    Label(acao.titulo, systemImage: acao.icone)
                                }
                                .tint(acao.bloquear ? Tema.vermelho : Tema.verde)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .contextMenu { menu(a) }
                        .onTapGesture {
                            novoNome = estado.nomes[a.mac] ?? ""
                            renomeando = a
                        }
                }
            }
            .listStyle(.plain)
            .animation(.snappy, value: saindo)
            .searchable(text: $busca, prompt: "Nome, IP ou MAC")
            .refreshable { await estado.atualizar() }
            .navigationTitle("Aparelhos")
            .telaEscura()
            .alert("Nome no app", isPresented: Binding(get: { renomeando != nil },
                                                     set: { if !$0 { renomeando = nil } })) {
                TextField(renomeando?.nomeRede.isEmpty == false ? renomeando!.nomeRede : "Nome", text: $novoNome)
                Button("Salvar") {
                    if let a = renomeando { estado.renomear(mac: a.mac, para: novoNome) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Fica só neste iPhone. Deixe vazio para voltar ao nome que o aparelho informa.")
            }
            .alert("Wi-Fi", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(aviso ?? "")
            }
            .confirmationDialog("Ligar \"só autorizados\"?", isPresented: $perguntandoLigar,
                                titleVisibility: .visible) {
                Button("Autorizar os \(conectadosWifi) conectados e ligar") {
                    executar { await estado.autorizarConectados() } depois: { await estado.definirSoAutorizados(true) }
                }
                if (estado.acl?.allow.count ?? 0) > 0 {
                    Button("Ligar com a lista atual (\(estado.acl?.allow.count ?? 0))", role: .destructive) {
                        executar { await estado.definirSoAutorizados(true) }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(mensagemLigar)
            }
            .confirmationDialog("Voltar para a lista de bloqueio?", isPresented: $perguntandoDesligar,
                                titleVisibility: .visible) {
                Button("Voltar para a lista de bloqueio") {
                    executar { await estado.definirSoAutorizados(false) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Qualquer aparelho com a senha volta a conseguir entrar, menos os da lista de bloqueio. A lista de autorizados fica guardada para a próxima vez.")
            }
        }
    }

    // MARK: cartão do controle de acesso

    private var controle: some View {
        let acl = estado.acl
        let so = acl?.soAutorizados == true
        return Cartao(titulo: "Acesso ao Wi-Fi", icone: so ? "lock.shield.fill" : "lock.open") {
            Picker("Modo", selection: Binding(get: { so }, set: { novo in
                if novo != so {
                    if novo { perguntandoLigar = true } else { perguntandoDesligar = true }
                }
            })) {
                Text("Lista de bloqueio").tag(false)
                Text("Só autorizados").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(ocupado || acl == nil)

            Text(so
                 ? "Só os aparelhos da lista entram (\(acl?.allow.count ?? 0)). Os outros não conseguem conectar, mesmo com a senha."
                 : "Qualquer aparelho com a senha entra, menos os bloqueados (\(acl?.deny.count ?? 0)).")
                .font(.caption)
                .foregroundStyle(Tema.texto2)

            Button {
                executar { await estado.autorizarConectados() }
            } label: {
                Label("Autorizar os \(conectadosWifi) conectados agora", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(ocupado || acl == nil)

            if ocupado {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private var conectadosWifi: Int {
        estado.aparelhos.filter { $0.banda == .g5 || $0.banda == .g2 }.count
    }

    private var mensagemLigar: String {
        let fora = estado.ficariamDeFora
        if (estado.acl?.allow.count ?? 0) == 0 {
            return "Os \(conectadosWifi) aparelhos conectados agora entram na lista e continuam conectados. Quem não estiver na lista não consegue mais entrar, mesmo com a senha."
        }
        if fora.isEmpty {
            return "Todos os conectados agora já estão autorizados. Ninguém cai."
        }
        let nomes = fora.prefix(6).map { $0.nome }.joined(separator: ", ")
        return "Com a lista atual, \(fora.count) conectados cairiam: \(nomes)\(fora.count > 6 ? "…" : ""). Para manter todos, use \"Autorizar os conectados e ligar\"."
    }

    private func executar(_ passo: @escaping () async -> String?,
                          depois: (() async -> String?)? = nil) {
        ocupado = true
        Task {
            var erro = await passo()
            if erro == nil, let depois { erro = await depois() }
            ocupado = false
            if let erro { aviso = erro }
        }
    }

    // MARK: gesto e menu

    private struct Acao {
        var titulo: String
        var icone: String
        var bloquear: Bool
    }

    private func acaoDoGesto(_ a: Aparelho) -> Acao? {
        if a.euMesmo { return nil }
        let so = estado.acl?.soAutorizados == true
        switch a.banda {
        case .g5, .g2:
            return Acao(titulo: "Bloquear", icone: "hand.raised.fill", bloquear: true)
        case .controle:
            return so ? Acao(titulo: "Remover", icone: "person.badge.minus", bloquear: true)
                      : Acao(titulo: "Desbloquear", icone: "hand.thumbsup.fill", bloquear: false)
        case .cabo:
            return nil
        }
    }

    @ViewBuilder
    private func menu(_ a: Aparelho) -> some View {
        Button {
            novoNome = estado.nomes[a.mac] ?? ""
            renomeando = a
        } label: {
            Label("Renomear", systemImage: "pencil")
        }
        if let ip = a.ip {
            Button {
                UIPasteboard.general.string = ip
            } label: {
                Label("Copiar IP", systemImage: "doc.on.doc")
            }
        }
        Button {
            UIPasteboard.general.string = a.mac
        } label: {
            Label("Copiar MAC", systemImage: "doc.on.doc")
        }
        if let acao = acaoDoGesto(a) {
            if acao.bloquear {
                Button(role: .destructive) {
                    alternar(a, bloquear: true)
                } label: {
                    Label(acao.titulo == "Remover" ? "Remover dos autorizados" : "Bloquear no Wi-Fi",
                          systemImage: acao.icone)
                }
            } else {
                Button {
                    alternar(a, bloquear: false)
                } label: {
                    Label(acao.titulo, systemImage: acao.icone)
                }
            }
        }
    }

    private func alternar(_ a: Aparelho, bloquear: Bool) {
        saindo.insert(a.mac)
        Task {
            let erro = await estado.bloquear(mac: a.mac, bloquear)
            saindo.remove(a.mac)
            if let erro { aviso = erro }
        }
    }

    private func rodape(_ n: Int) -> String {
        let so = estado.acl?.soAutorizados == true
        switch banda {
        case .controle:
            if so { return n == 0 ? "Nenhum autorizado." : "Autorizados (\(n)). Arraste para a esquerda para remover." }
            return n == 0 ? "Nenhum aparelho bloqueado." : "Bloqueados (\(n)). Arraste para a esquerda para desbloquear."
        case .cabo:
            return "\(n) por cabo. Inclui os aparelhos atrás do roteador IoT (LAN1) e as máquinas virtuais do GT-SRV."
        case .g5, .g2:
            if estado.dados == nil { return "Sem dados do roteador." }
            return "\(n) conectados. Arraste para a esquerda para bloquear no Wi-Fi."
        }
    }

    private var filtrados: [Aparelho] {
        let todos = estado.aparelhos.filter { $0.banda == banda }
        let b = busca.trimmingCharacters(in: .whitespaces).lowercased()
        guard !b.isEmpty else { return todos }
        return todos.filter {
            $0.nome.lowercased().contains(b) || ($0.ip ?? "").contains(b) || $0.mac.contains(b)
                || $0.nomeRede.lowercased().contains(b)
        }
    }
}

struct LinhaAparelho: View {
    let a: Aparelho

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if a.banda == .cabo {
                    Image(systemName: "cable.connector")
                } else if a.banda == .controle {
                    Image(systemName: a.online ? "wifi" : "wifi.slash")
                } else {
                    Image(systemName: "wifi", variableValue: a.sinal)
                }
            }
            .font(.title3)
            .foregroundStyle(cor)
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(a.nome)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(a.nome == "Sem nome" ? Tema.texto2 : .primary)
                    .lineLimit(1)
                Text([a.ip, a.mac].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(Tema.texto2)
                    .lineLimit(1)
                if let porta = a.porta {
                    Text(porta).font(.caption).foregroundStyle(Tema.texto2)
                }
                if let c = a.conectado {
                    Text("conectado há \(c)").font(.caption2).foregroundStyle(Tema.texto2)
                }
                if a.banda == .controle {
                    Text(a.online ? "conectado agora" : "fora do ar").font(.caption2).foregroundStyle(Tema.texto2)
                }
                if a.euMesmo {
                    Text("este iPhone").font(.caption2.weight(.semibold)).foregroundStyle(Tema.acento)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let r = a.rssi {
                    Text("\(r) dBm").font(.caption.monospacedDigit()).foregroundStyle(cor)
                }
                if let tx = a.taxaTx, let rx = a.taxaRx {
                    Text("↓\(tx) ↑\(rx) Mb/s").font(.caption2.monospacedDigit()).foregroundStyle(Tema.texto2)
                }
                if (a.baixando ?? 0) > 0 || (a.enviando ?? 0) > 0 {
                    Text("agora ↓\(Fmt.taxa(a.baixando)) ↑\(Fmt.taxa(a.enviando))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Tema.acento)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }

    private var cor: Color {
        if a.banda == .controle { return a.online ? Tema.acento : Tema.texto2 }
        guard a.banda != .cabo else { return Tema.acento }
        switch a.sinal {
        case 0.9...: return Tema.verde
        case 0.5...: return Tema.acento
        case 0.2...: return Tema.laranja
        default: return Tema.vermelho
        }
    }
}
