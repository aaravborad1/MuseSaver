import Foundation
import Network

/// A tiny single-shot HTTP server that listens on 127.0.0.1 to catch the OAuth
/// redirect and extract the `code` query parameter.
final class LocalCallbackServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port

    var onCode: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind explicitly to loopback so nothing external can reach it.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            tcp.version = .v4
        }
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                self.process(request: request, connection: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func process(request: String, connection: NWConnection) {
        // The request line looks like: GET /callback?code=...&state=... HTTP/1.1
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let components = firstLine.split(separator: " ")

        var code: String?
        var errorParam: String?
        if components.count >= 2,
           let urlComponents = URLComponents(string: "http://127.0.0.1" + components[1]) {
            let items = urlComponents.queryItems ?? []
            code = items.first(where: { $0.name == "code" })?.value
            errorParam = items.first(where: { $0.name == "error" })?.value
        }

        let body: String
        if code != nil {
            body = Self.htmlPage(title: "MuseSaver connected",
                                 message: "You can close this tab and return to the app.")
        } else {
            body = Self.htmlPage(title: "Authorization failed",
                                 message: errorParam ?? "Unknown error.")
        }

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        if let code {
            onCode?(code)
        } else if let errorParam {
            onError?(NSError(domain: "MuseSaver", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "Spotify authorization error: \(errorParam)"]))
        }
        stop()
    }

    private static func htmlPage(title: String, message: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;background:#0b0b0f;color:#f5f5f7;text-align:center;padding-top:120px">
        <h1 style="font-weight:600">\(title)</h1>
        <p style="opacity:0.7">\(message)</p>
        </body></html>
        """
    }
}
