import Foundation

/// Mede vazão com vários fluxos em paralelo durante alguns segundos.
/// Download: soma os bytes recebidos. Upload: soma os bytes enviados (pedaços de 4 MB repetidos).
/// O primeiro segundo é descartado (aquecimento do TCP); o número final é a média do resto.
final class Medidor: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Tipo { case download, upload }

    private let tipo: Tipo
    private let fluxos: Int
    private let pedido: () -> URLRequest
    private let corpo: Data
    private let trava = NSLock()
    private var bytes: Int64 = 0
    private var ativo = false
    private var falha: String?
    private var sessao: URLSession?

    static let pedaco: Data = {
        var d = Data(count: 4 * 1024 * 1024)
        d.withUnsafeMutableBytes { p in
            if let base = p.baseAddress { arc4random_buf(base, p.count) }
        }
        return d
    }()

    init(tipo: Tipo, fluxos: Int, pedido: @escaping () -> URLRequest) {
        self.tipo = tipo
        self.fluxos = fluxos
        self.pedido = pedido
        self.corpo = tipo == .upload ? Medidor.pedaco : Data()
    }

    private func somar(_ n: Int64) {
        trava.lock()
        bytes += n
        trava.unlock()
    }

    private func lerBytes() -> Int64 {
        trava.lock()
        defer { trava.unlock() }
        return bytes
    }

    private var estaAtivo: Bool {
        trava.lock()
        defer { trava.unlock() }
        return ativo
    }

    private func abrir() {
        guard estaAtivo, let s = sessao else { return }
        let r = pedido()
        let t: URLSessionTask = tipo == .download ? s.dataTask(with: r) : s.uploadTask(with: r, from: corpo)
        t.resume()
    }

    /// Devolve Mb/s. `progresso` recebe a taxa instantânea (suavizada) a cada 0,25 s.
    func medir(segundos: Double, progresso: @escaping @MainActor (Double) -> Void) async throws -> Double {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = fluxos
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let fila = OperationQueue()
        fila.maxConcurrentOperationCount = 1
        sessao = URLSession(configuration: cfg, delegate: self, delegateQueue: fila)
        trava.withLock {
            ativo = true
            bytes = 0
            falha = nil
        }
        for _ in 0..<fluxos { abrir() }

        let inicio = Date()
        var base: Int64 = -1
        var tBase = inicio
        var anterior: Int64 = 0
        var tAnterior = inicio
        var suave = 0.0
        while Date().timeIntervalSince(inicio) < segundos {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            let agora = Date()
            let b = lerBytes()
            let dt = agora.timeIntervalSince(tAnterior)
            if dt > 0 {
                let inst = Double(b - anterior) * 8 / dt / 1e6
                suave = suave == 0 ? inst : suave * 0.7 + inst * 0.3
                await progresso(suave)
            }
            anterior = b
            tAnterior = agora
            if base < 0 && agora.timeIntervalSince(inicio) >= 1.0 {
                base = b
                tBase = agora
            }
            let f = trava.withLock { falha }
            if let f, b == 0 {
                parar()
                throw ErroApp(f)
            }
        }
        let fim = Date()
        let total = lerBytes()
        parar()
        if base < 0 { base = 0; tBase = inicio }
        let dur = fim.timeIntervalSince(tBase)
        guard dur > 0 else { return 0 }
        return Double(total - base) * 8 / dur / 1e6
    }

    private func parar() {
        trava.lock()
        ativo = false
        trava.unlock()
        sessao?.invalidateAndCancel()
        sessao = nil
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard tipo == .download else { return }
        if let h = dataTask.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            trava.lock()
            falha = h.statusCode == 403 ? "O servidor recusou o token. Confira em Ajustes." : "HTTP \(h.statusCode)"
            trava.unlock()
            return
        }
        somar(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard tipo == .upload else { return }
        somar(bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if tipo == .upload, let h = task.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            trava.lock()
            falha = h.statusCode == 403 ? "O servidor recusou o token. Confira em Ajustes." : "HTTP \(h.statusCode)"
            trava.unlock()
        }
        if let e = error as? URLError, e.code != .cancelled {
            trava.lock()
            if falha == nil { falha = e.localizedDescription }
            trava.unlock()
        }
        // um fluxo terminou antes do tempo: abre outro no lugar
        if estaAtivo {
            let fila = DispatchQueue.global(qos: .userInitiated)
            fila.async { [weak self] in self?.abrir() }
        }
    }
}

/// Latência: mediana de 5 pedidos pequenos (depois de um de aquecimento, que abre a conexão).
enum Latencia {
    static func medir(_ fazer: () -> URLRequest) async -> Double? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.urlCache = nil
        let s = URLSession(configuration: cfg)
        defer { s.finishTasksAndInvalidate() }
        _ = try? await s.data(for: fazer())
        var tempos: [Double] = []
        for _ in 0..<5 {
            let t0 = Date()
            if (try? await s.data(for: fazer())) != nil {
                tempos.append(Date().timeIntervalSince(t0) * 1000)
            }
        }
        guard !tempos.isEmpty else { return nil }
        tempos.sort()
        return tempos[tempos.count / 2]
    }
}
