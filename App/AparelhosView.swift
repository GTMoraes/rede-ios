import SwiftUI
import UIKit

struct AparelhosView: View {
    @Environment(Estado.self) private var estado
    @State private var banda: Banda = .g5
    @State private var editando: Aparelho?
    @State private var busca = ""
    /// Linhas que acabaram de ser arrastadas até o fim: saem da tela enquanto o roteador aplica.
    @State private var saindo = Set<String>()
    @State private var aviso: String?
    /// Modo pedido no seletor, esperando confirmação ("deny", "approve" ou "allow").
    @State private var modoPedido: String?
    @Bindable private var nav = Navegacao.shared
    @State private var ocupado = false
    /// Portas recolhidas na aba Cabo (por padrão, todas abertas).
    @State private var fechadas = Set<String>()
    /// Aba Controle: autorizados fora do ar e bloqueados ficam escondidos até tocar no botão.
    @State private var verAutorizadosFora = false
    @State private var verBloqueados = false

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
                .linhaDeLista(topo: 8, base: 4)

                if banda == .controle {
                    controle.linhaDeLista()
                }

                Text(rodape(lista.count))
                    .font(.caption)
                    .foregroundStyle(Tema.texto2)
                    .linhaDeLista(topo: 0, base: 4, esquerda: 20)

                if Fabricantes.pareceMAC(busca) {
                    CartaoConsultaMAC(texto: busca, naRede: naRedeConsulta)
                        .linhaDeLista()
                }

                if banda == .cabo {
                    linhasCabo(lista)
                } else if banda == .controle {
                    linhasControle(lista)
                } else {
                    ForEach(lista) { a in
                        linhaSimples(a)
                    }
                }
            }
            .listStyle(.plain)
            .animation(.snappy, value: saindo)
            .searchable(text: $busca, prompt: "Nome, IP ou MAC")
            .refreshable { await estado.atualizar() }
            .navigationTitle("Aparelhos")
            .telaEscura()
            .sheet(item: $editando) { a in
                EditarAparelhoView(a: a)
            }
            .alert("Wi-Fi", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(aviso ?? "")
            }
            .confirmationDialog(tituloModo, isPresented: Binding(get: { modoPedido != nil },
                                                                 set: { if !$0 { modoPedido = nil } }),
                                titleVisibility: .visible, presenting: modoPedido) { m in
                botoesModo(m)
            } message: { m in
                Text(mensagemModo(m))
            }
            // tocar no aviso de aparelho novo abre direto a aba Controle
            .onChange(of: nav.pedidoPendentes, initial: true) { _, pedido in
                if pedido {
                    banda = .controle
                    nav.pedidoPendentes = false
                }
            }
        }
    }

    // MARK: linhas

    /// Aparelho de Wi-Fi ou da aba Controle: arrastar até a metade mostra o botão; até o fim, executa.
    private func linhaSimples(_ a: Aparelho) -> some View {
        LinhaAparelho(a: a)
            .offset(x: saindo.contains(a.mac) ? -700 : 0)
            .opacity(saindo.contains(a.mac) ? 0 : 1)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                botaoDoGesto(a)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if a.situacao == .pendente {
                    Button {
                        executar { await estado.aprovar(mac: a.mac) }
                    } label: {
                        Label("Aprovar", systemImage: "checkmark.circle.fill")
                    }
                    .tint(Tema.verde)
                } else if podeEsquecer(a) {
                    Button {
                        esquecer(a)
                    } label: {
                        Label("Esquecer", systemImage: "trash")
                    }
                    .tint(.gray)
                }
            }
            .linhaDeLista()
            .contextMenu { menu(a) }
            .onTapGesture { editando = a }
    }

    /// Aba Controle: pendentes e quem está conectado sempre à vista; autorizados fora do ar e bloqueados atrás de
    /// um botão cada (na busca, aparece tudo).
    @ViewBuilder
    private func linhasControle(_ lista: [Aparelho]) -> some View {
        let tudo = !busca.isEmpty
        let fora = lista.filter { $0.situacao == .autorizado && !$0.online }
        let bloqueados = lista.filter { $0.situacao == .bloqueado && !$0.online }
        ForEach(lista.filter { $0.situacao == .pendente || $0.online }) { a in
            linhaSimples(a)
        }
        grupoEscondido(fora, titulo: "autorizados fora do ar", aberto: $verAutorizadosFora, tudo: tudo)
        grupoEscondido(bloqueados, titulo: bloqueados.count == 1 ? "bloqueado" : "bloqueados",
                       aberto: $verBloqueados, tudo: tudo)
    }

    @ViewBuilder
    private func grupoEscondido(_ itens: [Aparelho], titulo: String, aberto: Binding<Bool>, tudo: Bool) -> some View {
        if !itens.isEmpty {
            if !tudo {
                Button {
                    withAnimation(.snappy) { aberto.wrappedValue.toggle() }
                } label: {
                    Label("\(aberto.wrappedValue ? "Esconder" : "Mostrar") \(itens.count) \(titulo)",
                          systemImage: aberto.wrappedValue ? "eye.slash" : "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .linhaDeLista()
            }
            if aberto.wrappedValue || tudo {
                ForEach(itens) { a in
                    linhaSimples(a)
                }
            }
        }
    }

    /// "Esquecer" (tirar das listas) vale para quem está na aba Controle e fora do ar.
    private func podeEsquecer(_ a: Aparelho) -> Bool {
        a.banda == .controle && !a.online && !a.euMesmo && a.situacao != .pendente
    }

    private func esquecer(_ a: Aparelho) {
        saindo.insert(a.mac)
        Task {
            let erro = await estado.esquecer(mac: a.mac)
            saindo.remove(a.mac)
            if let erro { aviso = erro }
        }
    }

    @ViewBuilder
    private func botaoDoGesto(_ a: Aparelho) -> some View {
        if let acao = acaoDoGesto(a) {
            Button {
                alternar(a, bloquear: acao.bloquear)
            } label: {
                Label(acao.titulo, systemImage: acao.icone)
            }
            .tint(acao.bloquear ? Tema.vermelho : Tema.verde)
        }
    }

    /// Aba Cabo: cada porta ("pai") com os aparelhos atrás dela ("filhos").
    @ViewBuilder
    private func linhasCabo(_ lista: [Aparelho]) -> some View {
        ForEach(grupos(lista)) { g in
            linhasGrupo(g)
        }
    }

    @ViewBuilder
    private func linhasGrupo(_ g: Grupo) -> some View {
        let aberta = !fechadas.contains(g.dev) || !busca.isEmpty
        LinhaGrupoPorta(g: g, aberta: aberta)
            .linhaDeLista()
            .onTapGesture {
                withAnimation(.snappy) { alternarPorta(g.dev) }
            }
        if aberta {
            ForEach(g.filhos) { a in
                LinhaAparelho(a: a, filho: true)
                    .linhaDeLista(topo: 4, base: 4, esquerda: 40)
                    .contextMenu { menu(a) }
                    .onTapGesture { editando = a }
            }
        }
    }

    // MARK: cartão do controle de acesso

    private var controle: some View {
        let acl = estado.acl
        let modo = acl?.mode ?? "deny"
        return Cartao(titulo: "Acesso ao Wi-Fi", icone: modo == "deny" ? "lock.open" : "lock.shield.fill") {
            Picker("Modo", selection: Binding(get: { modo }, set: { novo in
                if novo != modo { modoPedido = novo }
            })) {
                Text("Bloqueio").tag("deny")
                Text("Aprovação").tag("approve")
                Text("Autorizados").tag("allow")
            }
            .pickerStyle(.segmented)
            .disabled(ocupado || acl == nil)

            Text(descricao(modo))
                .font(.caption)
                .foregroundStyle(Tema.texto2)

            if modo != "approve" {
                botaoAutorizar
            }

            if ocupado {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    /// Copia para a lista de autorizados quem está no Wi-Fi e ainda não está nela (fora do modo aprovação).
    private var botaoAutorizar: some View {
        let novos = estado.naoAutorizados.count
        return Button {
            executar({ await estado.autorizarConectados() }, sucesso: "\(novos) autorizado\(novos == 1 ? "" : "s").")
        } label: {
            Label(novos == 0
                  ? "Todos os \(conectadosWifi) conectados estão autorizados"
                  : "Autorizar \(novos) de \(conectadosWifi) conectados",
                  systemImage: novos == 0 ? "checkmark.seal.fill" : "person.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(novos == 0 ? Tema.verde : Tema.acento)
        .disabled(ocupado || estado.acl == nil || novos == 0)
    }

    private func descricao(_ modo: String) -> String {
        let acl = estado.acl
        switch modo {
        case "allow":
            return "Só os aparelhos da lista entram (\(acl?.allow.count ?? 0)). Os outros não conseguem conectar, mesmo com a senha."
        case "approve":
            return "Quem tem a senha conecta, mas aparelho novo fica sem rede até você aprovar. Você recebe um aviso no iPhone."
        default:
            return "Qualquer aparelho com a senha entra, menos os bloqueados (\(acl?.deny.count ?? 0))."
        }
    }

    private var tituloModo: String {
        switch modoPedido {
        case "allow": return "Ligar \"só autorizados\"?"
        case "approve": return "Ligar a aprovação?"
        default: return "Voltar para a lista de bloqueio?"
        }
    }

    @ViewBuilder
    private func botoesModo(_ m: String) -> some View {
        if m == "deny" {
            Button("Voltar para a lista de bloqueio") {
                executar { await estado.definirModo("deny") }
            }
        } else if estado.acl?.aprovacao == true {
            Button("Ligar \"só autorizados\"") {
                executar { await estado.definirModo(m) }
            }
        } else {
            let faltam = estado.naoAutorizados.count
            let naLista = estado.acl?.allow.count ?? 0
            Button(faltam == 0 ? "Ligar" : "Autorizar os \(faltam) conectados que faltam e ligar") {
                executar { await estado.autorizarConectados() } depois: { await estado.definirModo(m) }
            }
            if naLista > 0 && faltam > 0 {
                Button("Ligar com a lista atual (\(naLista))", role: .destructive) {
                    executar { await estado.definirModo(m) }
                }
            }
        }
        Button("Cancelar", role: .cancel) {}
    }

    private func mensagemModo(_ m: String) -> String {
        if m == "deny" {
            return "Qualquer aparelho com a senha volta a conseguir entrar, menos os bloqueados. As listas ficam guardadas para a próxima vez."
        }
        if estado.acl?.aprovacao == true {
            let p = estado.pendentes.count
            return "Os autorizados continuam. " + (p == 0 ? "" : "Os \(p) pendentes caem e não conseguem mais entrar, mesmo com a senha.")
        }
        let fora = estado.ficariamDeFora
        let efeito = m == "allow"
            ? "Quem não estiver na lista não consegue mais entrar, mesmo com a senha."
            : "Quem não estiver na lista conecta, mas fica sem rede até você aprovar."
        if (estado.acl?.allow.count ?? 0) == 0 {
            return "Os \(conectadosWifi) aparelhos conectados agora entram na lista e continuam conectados. \(efeito)"
        }
        if fora.isEmpty {
            return "Todos os conectados agora já estão autorizados. Ninguém cai. \(efeito)"
        }
        let nomes = fora.prefix(6).map { $0.nome }.joined(separator: ", ")
        let destino = m == "allow" ? "cairiam" : "cairiam e voltariam como pendentes"
        return "Com a lista atual, \(fora.count) conectados \(destino): \(nomes)\(fora.count > 6 ? "…" : ""). Para manter todos, use \"Autorizar os conectados que faltam e ligar\"."
    }

    private var conectadosWifi: Int {
        estado.aparelhos.filter { $0.banda == .g5 || $0.banda == .g2 }.count
    }

    private func executar(_ passo: @escaping () async -> String?,
                          depois: (() async -> String?)? = nil,
                          sucesso: String? = nil) {
        ocupado = true
        Task {
            var erro = await passo()
            if erro == nil, let depois { erro = await depois() }
            ocupado = false
            if let erro { aviso = erro } else if let sucesso { aviso = sucesso }
        }
    }

    // MARK: árvore da aba Cabo (porta → aparelhos)

    struct Grupo: Identifiable {
        var dev: String
        var porta: Porta?
        var filhos: [Aparelho]
        var id: String { dev }
    }

    private func alternarPorta(_ dev: String) {
        if fechadas.contains(dev) {
            _ = fechadas.remove(dev)
        } else {
            _ = fechadas.insert(dev)
        }
    }

    private func grupos(_ lista: [Aparelho]) -> [Grupo] {
        var porDev: [String: [Aparelho]] = [:]
        for a in lista { porDev[a.dev ?? "?", default: []].append(a) }
        return porDev.keys.sorted().map { dev in
            Grupo(dev: dev, porta: estado.porta(dev: dev), filhos: porDev[dev] ?? [])
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
            if a.situacao == .pendente {
                return Acao(titulo: "Recusar", icone: "hand.raised.fill", bloquear: true)
            }
            return Acao(titulo: "Bloquear", icone: "hand.raised.fill", bloquear: true)
        case .controle:
            switch a.situacao {
            case .pendente:
                return Acao(titulo: "Recusar", icone: "hand.raised.fill", bloquear: true)
            case .bloqueado:
                return Acao(titulo: "Desbloquear", icone: "hand.thumbsup.fill", bloquear: false)
            default:
                return so ? Acao(titulo: "Remover", icone: "person.badge.minus", bloquear: true)
                          : Acao(titulo: "Bloquear", icone: "hand.raised.fill", bloquear: true)
            }
        case .cabo:
            return nil
        }
    }

    @ViewBuilder
    private func menu(_ a: Aparelho) -> some View {
        Button {
            editando = a
        } label: {
            Label("Nome e IP fixo", systemImage: "pencil")
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
        if a.situacao == .pendente {
            Button {
                executar { await estado.aprovar(mac: a.mac) }
            } label: {
                Label("Aprovar", systemImage: "checkmark.circle.fill")
            }
        }
        if podeEsquecer(a) {
            Button {
                esquecer(a)
            } label: {
                Label("Esquecer (tirar da lista)", systemImage: "trash")
            }
        }
        if let acao = acaoDoGesto(a) {
            if acao.bloquear {
                Button(role: .destructive) {
                    alternar(a, bloquear: true)
                } label: {
                    Label(acao.titulo == "Remover" ? "Remover dos autorizados"
                          : (acao.titulo == "Recusar" ? "Recusar" : "Bloquear no Wi-Fi"),
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
            if estado.acl?.aprovacao == true {
                let p = estado.pendentes.count
                let base = p == 0 ? "Nenhum pendente. " : "\(p) esperando aprovação: arraste para a direita para aprovar, para a esquerda para recusar. "
                return base + "Quem está fora do ar fica escondido abaixo; arraste para a direita para esquecer."
            }
            if so { return n == 0 ? "Nenhum autorizado." : "Autorizados (\(n)). Arraste para a esquerda para remover; para a direita, esquecer quem está fora do ar." }
            return n == 0 ? "Nenhum aparelho bloqueado." : "Bloqueados (\(n)). Arraste para a esquerda para desbloquear; para a direita, esquecer."
        case .cabo:
            return "\(n) por cabo, agrupados pela porta. Toque numa porta para mostrar ou esconder os aparelhos."
        case .g5, .g2:
            if estado.dados == nil { return "Sem dados do roteador." }
            return "\(n) conectados. Arraste para a esquerda para bloquear no Wi-Fi."
        }
    }

    /// Quantos aparelhos conhecidos começam com o MAC buscado.
    private var naRedeConsulta: Int {
        let h = Fabricantes.hex(busca)
        let macs = Set(estado.aparelhos.map { $0.mac })
        return macs.filter { Fabricantes.hex($0).hasPrefix(h) }.count
    }

    private var filtrados: [Aparelho] {
        let todos = estado.aparelhos.filter { $0.banda == banda }
        let b = busca.trimmingCharacters(in: .whitespaces).lowercased()
        guard !b.isEmpty else { return todos }
        let h = Fabricantes.hex(b)
        return todos.filter { a in
            if a.nome.lowercased().contains(b) || a.nomeRede.lowercased().contains(b) { return true }
            if (a.ip ?? "").contains(b) || a.mac.contains(b) { return true }
            if (a.fabricante ?? "").lowercased().contains(b) { return true }
            return h.count >= 4 && Fabricantes.hex(a.mac).contains(h)
        }
    }
}

/// Linha "pai" da aba Cabo: a porta, com quantos aparelhos estão atrás dela.
struct LinhaGrupoPorta: View {
    let g: AparelhosView.Grupo
    let aberta: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .rotationEffect(.degrees(aberta ? 90 : 0))
                .foregroundStyle(Tema.texto2)
                .frame(width: 14)
            Image(systemName: "cable.connector.horizontal")
                .font(.title3)
                .foregroundStyle(Tema.acento)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(.body.weight(.semibold))
                Text("\(g.filhos.count) aparelho\(g.filhos.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Tema.texto2)
            }
            Spacer()
            if let p = g.porta, p.up {
                HStack(spacing: 6) {
                    Bolinha(cor: Tema.corVelocidade(p.speed))
                    Text("\(p.speed.map { "\($0)" } ?? "?") Mb/s")
                        .font(.subheadline.monospacedDigit())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }

    private var titulo: String {
        guard let p = g.porta else { return g.dev }
        return p.label.isEmpty ? p.port : "\(p.port) · \(p.label)"
    }
}

struct LinhaAparelho: View {
    let a: Aparelho
    var filho = false

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
                if a.nome == "Sem nome" || a.nomeRede.isEmpty, let f = a.fabricante {
                    Text(f).font(.caption).foregroundStyle(Tema.texto2).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if a.ipFixo != nil {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Tema.acento)
                    }
                    Text([a.ip ?? a.ipFixo, a.mac].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(Tema.texto2)
                        .lineLimit(1)
                }
                if let porta = a.porta, !filho {
                    Text(porta).font(.caption).foregroundStyle(Tema.texto2)
                }
                if let c = a.conectado {
                    Text("conectado há \(c)").font(.caption2).foregroundStyle(Tema.texto2)
                }
                if let t = textoSituacao {
                    Text(t)
                        .font(a.situacao == .pendente ? Font.caption2.weight(.semibold) : Font.caption2)
                        .foregroundStyle(a.situacao == .pendente ? Tema.laranja : Tema.texto2)
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
        .padding(filho ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: filho ? 16 : 20))
        .contentShape(Rectangle())
    }

    private var textoSituacao: String? {
        guard let sit = a.situacao else { return nil }
        if a.banda != .controle { return sit == .pendente ? sit.texto : nil }
        let onde = a.online ? "conectado agora" : "fora do ar"
        return sit.texto + " · " + onde
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

extension View {
    /// Linha de lista sem fundo nem separador (o vidro fica por conta da própria linha).
    func linhaDeLista(topo: CGFloat = 6, base: CGFloat = 6, esquerda: CGFloat = 16) -> some View {
        self.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: topo, leading: esquerda, bottom: base, trailing: 16))
    }
}

/// Resultado da busca quando o texto parece um MAC: fabricante pelo prefixo (tabela do app ou consulta online).
struct CartaoConsultaMAC: View {
    let texto: String
    let naRede: Int
    @State private var online: String?
    @State private var consultando = false

    var body: some View {
        let aleatorio = Fabricantes.aleatorio(texto)
        let local = Fabricantes.local(texto)
        Cartao(titulo: "Consulta de MAC", icone: "magnifyingglass") {
            LinhaInfo(rotulo: "Prefixo", valor: Fabricantes.prefixoFormatado(texto))
            if aleatorio {
                LinhaInfo(rotulo: "Fabricante", valor: "nenhum (MAC aleatório)", cor: Tema.laranja)
                Text("O segundo dígito (2, 6, A ou E) indica endereço inventado pelo próprio aparelho, sem fabricante registrado. É o \"endereço privado\" de iPhone, Android e Windows, ou o de máquinas virtuais. Para saber o que é, veja por onde ele conecta e o nome que ele informa.")
                    .font(.caption)
                    .foregroundStyle(Tema.texto2)
            } else {
                LinhaInfo(rotulo: "Fabricante",
                          valor: local ?? online ?? (consultando ? "consultando…" : "não encontrado"))
            }
            LinhaInfo(rotulo: "Na rede agora", valor: naRede == 0 ? "não" : "\(naRede)")
        }
        .task(id: Fabricantes.prefixo(texto) ?? "") {
            guard !aleatorio, local == nil else { return }
            consultando = true
            online = await Fabricantes.online(texto)
            consultando = false
        }
    }
}
