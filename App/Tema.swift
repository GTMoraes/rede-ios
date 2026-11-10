import SwiftUI

enum Tema {
    static let acento = Color(red: 0.25, green: 0.62, blue: 1.00)      // azul
    static let verde = Color(red: 0.20, green: 0.74, blue: 0.42)
    static let laranja = Color(red: 0.95, green: 0.58, blue: 0.20)
    static let vermelho = Color(red: 0.93, green: 0.30, blue: 0.30)
    static let fundo = Color(red: 0.055, green: 0.070, blue: 0.100)
    static let texto2 = Color(white: 0.68)

    /// Fundo escuro com brilhos discretos, para o vidro ter o que refletir.
    static var gradiente: some View {
        ZStack {
            fundo
            RadialGradient(colors: [acento.opacity(0.26), .clear], center: .topTrailing,
                           startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.10, green: 0.78, blue: 0.68).opacity(0.15), .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 480)
        }
        .ignoresSafeArea()
    }

    static func corVelocidade(_ mbps: Int?) -> Color {
        guard let mbps else { return .gray }
        return mbps >= 1000 ? verde : laranja
    }
}

/// Cartão de vidro usado em todas as telas.
struct Cartao<Conteudo: View>: View {
    var titulo: String?
    var icone: String?
    @ViewBuilder var conteudo: Conteudo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let titulo {
                Label(titulo, systemImage: icone ?? "circle")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            conteudo
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// Botão principal.
struct BotaoPrincipal: View {
    var titulo: String
    var icone: String
    var cor: Color = Tema.acento
    var desativado = false
    var acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Label(titulo, systemImage: icone)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(cor)
        .disabled(desativado)
    }
}

/// Linha "rótulo ........ valor" dos cartões.
struct LinhaInfo: View {
    var rotulo: String
    var valor: String
    var cor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(rotulo).foregroundStyle(Tema.texto2)
            Spacer(minLength: 12)
            Text(valor)
                .foregroundStyle(cor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// Bolinha de estado (verde, laranja, cinza).
struct Bolinha: View {
    var cor: Color
    var body: some View {
        Circle().fill(cor).frame(width: 9, height: 9)
    }
}

extension View {
    func telaEscura() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Tema.gradiente)
    }
}

/// Pergunta antes de uma ação. Uso: `confirmar = Confirmacao(titulo: "…") { … }` e `.confirmar($confirmar)`.
struct Confirmacao: Identifiable {
    let id = UUID()
    var titulo: String
    var mensagem = "Isso não pode ser desfeito."
    var botao = "Confirmar"
    var destrutivo = true
    var acao: () -> Void
}

extension View {
    func confirmar(_ c: Binding<Confirmacao?>) -> some View {
        alert(c.wrappedValue?.titulo ?? "Tem certeza?",
              isPresented: Binding(get: { c.wrappedValue != nil }, set: { if !$0 { c.wrappedValue = nil } }),
              presenting: c.wrappedValue) { x in
            if x.destrutivo { Button(x.botao, role: .destructive) { x.acao() } }
            else { Button(x.botao) { x.acao() } }
            Button("Cancelar", role: .cancel) {}
        } message: { x in
            Text(x.mensagem)
        }
    }
}

struct ErroApp: LocalizedError {
    let mensagem: String
    init(_ m: String) { mensagem = m }
    var errorDescription: String? { mensagem }
}

// MARK: - formatação

enum Fmt {
    static func mbps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static func duracao(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "—" }
        let t = Int(s)
        let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "\(t) s"
    }

    static func bytes(_ b: Double?) -> String {
        guard let b, b.isFinite else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary)
    }

    /// Taxa em bytes por segundo, mostrada em bits (como os planos de internet).
    static func taxa(_ bps: Double?) -> String {
        guard let bps, bps.isFinite, bps > 0 else { return "0" }
        let bits = bps * 8
        if bits >= 1e6 { return String(format: "%.1f Mb/s", bits / 1e6) }
        if bits >= 1e3 { return String(format: "%.0f kb/s", bits / 1e3) }
        return String(format: "%.0f b/s", bits)
    }

    static func ms(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f ms", v)
    }
}
