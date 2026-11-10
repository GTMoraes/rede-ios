import SwiftUI

struct AjustesView: View {
    @Environment(Estado.self) private var estado
    @AppStorage(Chave.token) private var token = ""
    @AppStorage(Chave.roteador) private var roteador = Padrao.roteador
    @AppStorage(Chave.servidorLAN) private var servidorLAN = Padrao.servidorLAN
    @AppStorage(Chave.servidorTS) private var servidorTS = Padrao.servidorTS
    @State private var testando = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Token do roteador", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Acesso")
                } footer: {
                    Text("Aparece no fim da instalação da API no roteador. Para ver de novo, no SSH: cat /etc/netmon/token")
                }

                Section {
                    campo("Roteador", $roteador, Padrao.roteador)
                    campo("GT-SRV em casa", $servidorLAN, Padrao.servidorLAN)
                    campo("GT-SRV pela Tailscale", $servidorTS, Padrao.servidorTS)
                } header: {
                    Text("Endereços")
                } footer: {
                    Text("Em casa o app fala direto com o roteador. Fora, passa pelo GT-SRV, pela Tailscale (que precisa estar ligada no iPhone).")
                }

                Section {
                    HStack {
                        Label(estado.modo.texto, systemImage: estado.modo.icone)
                        Spacer()
                        if testando { ProgressView() }
                    }
                    Button("Procurar de novo") {
                        Task {
                            testando = true
                            estado.redescobrir()
                            await estado.atualizar()
                            testando = false
                        }
                    }
                    .disabled(testando)
                    if let e = estado.erro {
                        Text(e).font(.footnote).foregroundStyle(Tema.laranja)
                    }
                } header: {
                    Text("Conexão")
                }

                Section {
                    LabeledContent("Aparelhos renomeados", value: "\(estado.nomes.count)")
                    if !estado.nomes.isEmpty {
                        Button("Esquecer os nomes dados no app", role: .destructive) {
                            for mac in estado.nomes.keys { estado.renomear(mac: mac, para: "") }
                        }
                    }
                    LabeledContent("Versão", value: versao)
                } header: {
                    Text("App")
                }
            }
            .navigationTitle("Ajustes")
            .telaEscura()
            .onChange(of: token) { _, _ in estado.redescobrir() }
            .onChange(of: roteador) { _, _ in estado.redescobrir() }
            .onChange(of: servidorLAN) { _, _ in estado.redescobrir() }
            .onChange(of: servidorTS) { _, _ in estado.redescobrir() }
        }
    }

    private func campo(_ rotulo: String, _ valor: Binding<String>, _ padrao: String) -> some View {
        LabeledContent(rotulo) {
            TextField(padrao, text: valor)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
        }
    }

    private var versao: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
