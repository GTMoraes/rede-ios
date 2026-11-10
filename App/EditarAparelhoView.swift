import SwiftUI

/// Nome e IP fixo de um aparelho. Grava no roteador, na mesma lista da tela
/// "DHCP static IP assignment" (e no banco de nomes da Xiaomi, que o app Mi WiFi também usa).
struct EditarAparelhoView: View {
    let a: Aparelho
    @Environment(Estado.self) private var estado
    @Environment(\.dismiss) private var fechar
    @State private var nome: String
    @State private var fixo: Bool
    @State private var ip: String
    @State private var salvando = false
    @State private var erro: String?

    init(a: Aparelho) {
        self.a = a
        _nome = State(initialValue: a.nome == "Sem nome" ? "" : a.nome)
        _fixo = State(initialValue: a.ipFixo != nil)
        _ip = State(initialValue: a.ipFixo ?? a.ip ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(a.nomeRede.isEmpty ? "Nome" : a.nomeRede, text: $nome)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nome")
                } footer: {
                    Text(a.nomeRede.isEmpty
                         ? "Fica no roteador: aparece também na interface do roteador e no app Mi WiFi."
                         : "Fica no roteador. Deixe vazio para voltar ao nome que o aparelho informa (\(a.nomeRede)).")
                }

                Section {
                    Toggle("IP fixo", isOn: $fixo.animation())
                    if fixo {
                        TextField("10.0.0.x", text: $ip)
                            .keyboardType(.decimalPad)
                            .font(.body.monospaced())
                    }
                } header: {
                    Text("Endereço")
                } footer: {
                    Text(rodapeIP)
                }

                Section {
                    LabeledContent("MAC", value: a.mac)
                    LabeledContent("IP agora", value: a.ip ?? "—")
                    LabeledContent("Conexão", value: a.porta ?? a.banda.rawValue)
                    if let c = a.conectado { LabeledContent("Conectado há", value: c) }
                } header: {
                    Text("Detalhes")
                }

                if let erro {
                    Section {
                        Text(erro).foregroundStyle(Tema.laranja)
                    }
                }
            }
            .navigationTitle(a.nome)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { fechar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if salvando {
                        ProgressView()
                    } else {
                        Button("Salvar") { Task { await salvar() } }
                            .disabled(!mudou)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var rodapeIP: String {
        if !fixo {
            return a.ipFixo == nil ? "O roteador escolhe o IP." : "Ao salvar, o IP deixa de ser fixo."
        }
        if let atual = a.ip, atual != ip.trimmingCharacters(in: .whitespaces) {
            return "O aparelho passa para o IP novo quando renovar a conexão (pode levar horas). Desligar e religar o Wi-Fi dele adianta."
        }
        return "Fixando o IP que ele já usa, vale na hora."
    }

    private var nomeOriginal: String { a.nome == "Sem nome" ? "" : a.nome }

    private var mudou: Bool {
        let ipLimpo = ip.trimmingCharacters(in: .whitespaces)
        if nome.trimmingCharacters(in: .whitespaces) != nomeOriginal { return true }
        if fixo != (a.ipFixo != nil) { return true }
        if fixo && ipLimpo != (a.ipFixo ?? "") { return true }
        return false
    }

    private func salvar() async {
        salvando = true
        erro = nil
        defer { salvando = false }
        if nome.trimmingCharacters(in: .whitespaces) != nomeOriginal {
            if let e = await estado.salvarNome(mac: a.mac, nome: nome) { erro = e; return }
        }
        let ipLimpo = ip.trimmingCharacters(in: .whitespaces)
        if fixo && ipLimpo != (a.ipFixo ?? "") {
            if let e = await estado.fixarIP(mac: a.mac, ip: ipLimpo) { erro = e; return }
        } else if !fixo && a.ipFixo != nil {
            if let e = await estado.desafixarIP(mac: a.mac) { erro = e; return }
        }
        fechar()
    }
}
