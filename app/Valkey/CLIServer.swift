import Foundation

/// The app's side of `valkey-app` (see CLI.swift): answers JSON requests on a local CFMessagePort,
/// acting on ServerStore exactly like the UI does. Only processes in this user's login session can reach it.
@MainActor
enum CLIServer {
    private static var port: CFMessagePort?

    static func listen() {
        var context = CFMessagePortContext()
        // Runs on the main run loop, so it's safe to touch the store here.
        port = CFMessagePortCreateLocal(nil, CLI.portName as CFString, { _, _, data, _ in
            let reply = MainActor.assumeIsolated { CLIServer.reply(to: data as Data?) }
            return Unmanaged.passRetained(reply as CFData)
        }, &context, nil)
        guard let port, let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            return NSLog("Valkey: couldn't open the command-line port \(CLI.portName)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private static func reply(to data: Data?) -> Data {
        var response = CLI.Response()
        do {
            guard let data else { throw CLI.Failure(message: "Empty request.", code: CLI.Failure.usage) }
            response = try handle(try JSONDecoder().decode(CLI.Request.self, from: data))
        } catch let failure as CLI.Failure {
            response.error = failure.message
            response.exitCode = failure.code
        } catch {
            response.error = "Bad request: \(error.localizedDescription)"
            response.exitCode = CLI.Failure.usage
        }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    private static func handle(_ request: CLI.Request) throws -> CLI.Response {
        let store = ServerStore.shared
        func found() throws -> ValkeyServer {
            let match = try CLI.resolve(request.server ?? "", in: store.servers.map(info))
            return store.servers.first { $0.id.uuidString == match.id }!
        }
        func answer(_ server: ValkeyServer) -> CLI.Response { CLI.Response(servers: [info(server)]) }
        /// start() reports problems it finds up front (not installed, missing module) in `failure`.
        func started(_ server: ValkeyServer) throws -> CLI.Response {
            if !server.isRunning, let failure = server.failure { throw CLI.Failure(message: failure) }
            return answer(server)
        }

        switch request.command {
        case "list":
            return CLI.Response(servers: store.servers.map(info))
        case "status":
            return answer(try found())
        case "start":
            let server = try found()
            server.isStopping ? server.restart() : server.start()
            return try started(server)
        case "restart":
            let server = try found()
            server.restart()
            return try started(server)
        case "stop":
            let server = try found()
            server.stop()
            return answer(server)
        case "delete":
            let server = try found()
            let response = answer(server)
            store.remove(server)
            return response
        case "url":
            let server = try found()
            guard let name = request.user else { return CLI.Response(url: server.connectionURL()) }
            guard let user = server.config.accounts.first(where: { $0.name == name }) else {
                throw CLI.Failure(message: "“\(server.config.name)” has no user named “\(name)”.", code: CLI.Failure.notFound)
            }
            return CLI.Response(url: server.connectionURL(for: user))
        case "create":
            let installed = VersionStore.shared.installed   // newest first
            guard let version = request.version ?? installed.first else {
                throw CLI.Failure(message: "No Valkey version is installed. Install one from Versions… in Valkey.app.")
            }
            guard installed.contains(version) else {
                throw CLI.Failure(message: "Valkey \(version) isn't installed. Installed: \(installed.joined(separator: ", ")).")
            }
            var config = store.newConfig()
            config.version = version
            config.name = request.name ?? "Valkey \(version)"
            if let port = request.port {
                config.port = port
                config.dataDirectory = store.defaultDataDirectory(port: port)
            }
            if let problem = store.problem(with: config) { throw CLI.Failure(message: problem) }
            store.add(config)
            return answer(store.server(id: config.id)!)
        default:
            throw CLI.Failure(message: "Unknown command \(request.command).", code: CLI.Failure.usage)
        }
    }

    private static func info(_ server: ValkeyServer) -> CLI.ServerInfo {
        let c = server.config
        let state = server.isStopping ? "stopping" : server.isRunning ? "running" : server.failure != nil ? "failed" : "stopped"
        return CLI.ServerInfo(id: c.id.uuidString, name: c.name, version: c.version, port: c.port, state: state,
                              pid: server.pid, failure: server.failure, modules: c.enabledModules,
                              startAutomatically: c.startAutomatically, dataDirectory: c.dataDirectory,
                              logFile: server.logURL.path)
    }
}
