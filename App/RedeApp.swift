import SwiftUI
import UIKit
import UserNotifications

@main
struct RedeApp: App {
    @UIApplicationDelegateAdaptor(Delegado.self) private var delegado
    @State private var estado = Estado()

    var body: some Scene {
        WindowGroup {
            RaizView()
                .environment(estado)
                .preferredColorScheme(.dark)
                .tint(Tema.acento)
        }
    }
}

/// Pedidos de navegação vindos de fora das telas (toque num aviso).
@MainActor
@Observable
final class Navegacao {
    static let shared = Navegacao()
    var aba = 0
    /// Pedido para abrir a aba Controle de Aparelhos (aviso de aparelho novo).
    var pedidoPendentes = false

    func abrirPendentes() {
        aba = 1
        pedidoPendentes = true
    }
}

struct RaizView: View {
    @Environment(Estado.self) private var estado
    @Environment(\.scenePhase) private var fase
    @Bindable private var nav = Navegacao.shared

    var body: some View {
        TabView(selection: $nav.aba) {
            Tab("Painel", systemImage: "gauge.with.dots.needle.67percent", value: 0) {
                PainelView()
            }
            Tab("Aparelhos", systemImage: "laptopcomputer.and.iphone", value: 1) {
                AparelhosView()
            }
            .badge(estado.pendentes.count)
            Tab("Velocidade", systemImage: "speedometer", value: 2) {
                VelocidadeView()
            }
            Tab("Ajustes", systemImage: "gearshape", value: 3) {
                AjustesView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // atualiza a cada 5 s enquanto o app está aberto (a tela de velocidade pausa durante os testes)
        .task(id: fase) {
            guard fase == .active else { return }
            estado.redescobrir()
            while !Task.isCancelled {
                if !estado.pausado { await estado.atualizar() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

/// Avisos (push pela Apple): pede permissão, guarda o token e trata os botões Aprovar / Recusar do aviso.
final class Delegado: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Fabricantes.preparar()
        let central = UNUserNotificationCenter.current()
        central.delegate = self
        let aprovar = UNNotificationAction(identifier: "APROVAR", title: "Aprovar", options: [])
        let recusar = UNNotificationAction(identifier: "RECUSAR", title: "Recusar", options: [.destructive])
        central.setNotificationCategories([
            UNNotificationCategory(identifier: "PEDIDO", actions: [aprovar, recusar], intentIdentifiers: [], options: [])
        ])
        central.requestAuthorization(options: [.alert, .sound, .badge]) { permitido, _ in
            guard permitido else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Chave.tokenPush)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push: \(error.localizedDescription)")
    }

    // aviso com o app aberto: mostra mesmo assim
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // toque no aviso ou num dos botões
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let mac = response.notification.request.content.userInfo["mac"] as? String ?? ""
        switch response.actionIdentifier {
        case "APROVAR":
            await AcaoDoAviso.executar("approve", mac: mac)
        case "RECUSAR":
            await AcaoDoAviso.executar("block", mac: mac)
        default:
            await MainActor.run { Navegacao.shared.abrirPendentes() }
        }
    }
}

/// Aprovar / Recusar direto do aviso, com o app em segundo plano: acha o roteador e manda a ação.
enum AcaoDoAviso {
    static func executar(_ acao: String, mac: String) async {
        guard !mac.isEmpty, !Config.token.isEmpty else { return }
        let e = await Rede.descobrir()
        guard let base = e.roteador else { return }
        let r = Rede.pedido(Rede.url(base, "/api?a=\(acao)&mac=\(mac)"), metodo: "POST", timeout: 20)
        _ = try? await Rede.dados(r)
    }
}
