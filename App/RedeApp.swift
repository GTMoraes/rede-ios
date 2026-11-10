import SwiftUI

@main
struct RedeApp: App {
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

struct RaizView: View {
    @Environment(Estado.self) private var estado
    @Environment(\.scenePhase) private var fase

    var body: some View {
        TabView {
            Tab("Painel", systemImage: "gauge.with.dots.needle.67percent") {
                PainelView()
            }
            Tab("Aparelhos", systemImage: "laptopcomputer.and.iphone") {
                AparelhosView()
            }
            Tab("Velocidade", systemImage: "speedometer") {
                VelocidadeView()
            }
            Tab("Ajustes", systemImage: "gearshape") {
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
