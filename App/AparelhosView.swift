import SwiftUI
import UIKit

struct AparelhosView: View {
    @Environment(Estado.self) private var estado
    @State private var banda: Banda = .g5
    @State private var renomeando: Aparelho?
    @State private var novoNome = ""
    @State private var busca = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Banda", selection: $banda) {
                        ForEach(Banda.allCases) { b in
                            Text("\(b.rawValue) (\(estado.aparelhos.filter { $0.banda == b }.count))").tag(b)
                        }
                    }
                    .pickerStyle(.segmented)

                    let lista = filtrados
                    if lista.isEmpty {
                        Cartao {
                            Text(estado.dados == nil ? "Sem dados do roteador." : "Nenhum aparelho aqui.")
                                .foregroundStyle(Tema.texto2)
                        }
                    }
                    GlassEffectContainer(spacing: 12) {
                        LazyVStack(spacing: 12) {
                            ForEach(lista) { a in
                                LinhaAparelho(a: a)
                                    .contextMenu {
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
                                    }
                                    .onTapGesture {
                                        novoNome = estado.nomes[a.mac] ?? ""
                                        renomeando = a
                                    }
                            }
                        }
                    }
                    if banda == .cabo {
                        Text("Inclui os aparelhos atrás do roteador IoT (porta LAN1) e as máquinas virtuais do GT-SRV.")
                            .font(.caption)
                            .foregroundStyle(Tema.texto2)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
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
        guard a.banda != .cabo else { return Tema.acento }
        switch a.sinal {
        case 0.9...: return Tema.verde
        case 0.5...: return Tema.acento
        case 0.2...: return Tema.laranja
        default: return Tema.vermelho
        }
    }
}
