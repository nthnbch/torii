import Foundation
import Combine
import ServiceManagement

@MainActor
final class TorViewModel: ObservableObject {

    // MARK: - Published state

    @Published var status: TorConnectionStatus = .disconnected
    @Published var statusDetail: String = "Not connected"
    @Published var exitNode: ExitNode? = nil
    @Published var downloadSpeed: Double = 0   // bytes/s
    @Published var uploadSpeed: Double = 0     // bytes/s
    @Published var preferredCountry: ExitCountry = .any
    @Published var torVersion: String = TorManager.bundleVersion
    @Published var updateAvailable: String? = nil
    @Published var loginItemEnabled: Bool = false
    @Published var errorMessage: String? = nil
    @Published var publicIP: String? = nil
    @Published var isRenewingCircuit: Bool = false

    // MARK: - Private

    private let manager = TorManager()
    private let control = TorControlSocket()
    private let updateChecker = UpdateChecker()
    private var eventTask: Task<Void, Never>?
    private var bootstrapProgress: Int = 0
    private var preRenewalIP: String?

    // MARK: - Init

    init() {
        loginItemEnabled = (try? SMAppService.mainApp.status == .enabled) ?? false
        Task { await updateChecker.checkForUpdates() }
        Task { await fetchPublicIP() }
        Task {
            for await version in updateChecker.$updateAvailable.values {
                self.updateAvailable = version
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        guard status == .disconnected || status == .error else { return }
        status = .connecting
        statusDetail = "Starting Tor…"
        errorMessage = nil
        publicIP = nil

        Task {
            do {
                try manager.start()

                manager.onLogLine = { [weak self] line in
                    Task { @MainActor [weak self] in
                        if let progress = TorParser.parseBootstrapProgress(line) {
                            self?.bootstrapProgress = progress
                            let summary = TorParser.parseBootstrapSummary(line) ?? "Bootstrapping"
                            self?.statusDetail = "\(summary) (\(progress)%)"
                        }
                    }
                }

                manager.onProcessExit = { [weak self] code in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.status != .disconnected {
                            self.status = .error
                            self.statusDetail = "Tor exited (code \(code))"
                            self.exitNode = nil
                        }
                    }
                }

                // Wait until control port cookie is available
                statusDetail = "Waiting for cookie…"
                try await waitForCookie()
                let cookie = try manager.readAuthCookie()

                statusDetail = "Opening control port…"
                try await control.connect()
                statusDetail = "Authenticating…"
                try await control.authenticate(cookie: cookie)
                statusDetail = "Subscribing to events…"
                try await control.subscribeEvents(["BW", "STATUS_CLIENT", "CIRC"])

                // Read version
                if let v = try? await control.getInfo("version") {
                    torVersion = TorParser.parseVersion(from: v) ?? TorManager.bundleVersion
                }

                // *** Poll current bootstrap state immediately ***
                // Tor may have bootstrapped before we subscribed to events,
                // so we can't rely solely on STATUS_CLIENT events.
                statusDetail = "Checking bootstrap…"
                await checkBootstrapNow()

                startEventLoop()

            } catch {
                status = .error
                statusDetail = "Failed to start"
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        control.disconnect()
        manager.disableSystemProxy()
        manager.stop()
        status = .disconnected
        statusDetail = "Not connected"
        exitNode = nil
        downloadSpeed = 0
        uploadSpeed = 0
        bootstrapProgress = 0
        Task { await fetchPublicIP() }
    }

    // MARK: - New Circuit

    func requestNewCircuit() {
        guard status == .connected, !isRenewingCircuit else { return }
        isRenewingCircuit = true
        preRenewalIP = publicIP
        exitNode = nil
        publicIP = nil
        Task {
            try? await control.signal("NEWNYM")
            // Safety timeout: if CIRC BUILT never fires within 15 s, recover gracefully.
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if isRenewingCircuit {
                isRenewingCircuit = false
                if status == .connected {
                    await refreshExitNode()
                    await fetchPublicIPRetrying(avoiding: preRenewalIP)
                }
            }
        }
    }

    // MARK: - Country picker

    func setExitCountry(_ country: ExitCountry) {
        preferredCountry = country
        guard status == .connected else { return }
        Task {
            if country.id.isEmpty {
                try? await control.resetConf("ExitNodes")
                try? await control.resetConf("StrictNodes")
            } else {
                try? await control.setConf("ExitNodes", value: "{\(country.id)}")
                try? await control.setConf("StrictNodes", value: "1")
            }
            try? await control.signal("NEWNYM")
            exitNode = nil
            statusDetail = "Changing exit to \(country.id.isEmpty ? "any" : country.name)…"
            // Wait for Tor to build a new circuit with the requested exit
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if status == .connected {
                await refreshExitNode()
                await fetchPublicIP(viaSocks: true)
                statusDetail = "Connected"
            }
        }
    }

    // MARK: - Login item

    func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if loginItemEnabled {
                try service.unregister()
                loginItemEnabled = false
            } else {
                try service.register()
                loginItemEnabled = true
            }
        } catch {
            errorMessage = "Login item error: \(error.localizedDescription)"
        }
    }

    // MARK: - Bootstrap polling

    /// Called immediately after authenticating to get the current bootstrap state.
    /// Also starts a background poll that retries every 2s until PROGRESS=100.
    private func checkBootstrapNow() async {
        await pollBootstrap()

        // If not yet connected, keep polling every 2s in background
        if status != .connected {
            Task {
                while status == .connecting {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await pollBootstrap()
                }
            }
        }
    }

    private func pollBootstrap() async {
        guard let phase = try? await control.getInfo("status/bootstrap-phase") else {
            statusDetail = "Bootstrap poll failed"
            return
        }
        // phase looks like: "NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY=Done"
        if let progress = TorParser.parseBootstrapProgress(phase) {
            bootstrapProgress = progress
            if progress == 100 {
                status = .connected
                statusDetail = "Connected"
                manager.enableSystemProxy()
                Task { await self.refreshExitNode() }
                Task { await self.fetchPublicIP(viaSocks: true) }
            } else {
                let summary = TorParser.parseBootstrapSummary(phase) ?? "Bootstrapping"
                statusDetail = "\(summary) (\(progress)%)"
            }
        }
    }

    // MARK: - Event loop

    private func startEventLoop() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.control.eventStream {
                await MainActor.run { self.handleEvent(event) }
            }
        }
    }

    private func handleEvent(_ line: String) {
        // Bandwidth
        if let bw = TorParser.parseBWEvent(line) {
            downloadSpeed = Double(bw.read)
            uploadSpeed   = Double(bw.written)
            return
        }

        // Bootstrap status
        if line.contains("STATUS_CLIENT") {
            if let progress = TorParser.parseBootstrapProgress(line) {
                bootstrapProgress = progress
                let summary = TorParser.parseBootstrapSummary(line) ?? "Bootstrapping"
                if progress == 100 {
                    status = .connected
                    statusDetail = "Connected"
                    manager.enableSystemProxy()
                    Task { await self.refreshExitNode() }
                    Task { await self.fetchPublicIP(viaSocks: true) }
                } else {
                    status = .connecting
                    statusDetail = "\(summary) (\(progress)%)"
                }
            }
            return
        }

        // Circuit built → only act on full 3-hop exit circuits (not 2-hop internal ones)
        if TorParser.isExitCircuitBuilt(line) && status == .connected {
            statusDetail = "Connected"
            Task { await self.refreshExitNode() }
            if isRenewingCircuit {
                isRenewingCircuit = false
                let oldIP = preRenewalIP
                Task { await self.fetchPublicIPRetrying(avoiding: oldIP) }
            }
        }
    }

    // MARK: - Exit node detection

    private func refreshExitNode() async {
        guard status == .connected else { return }
        do {
            // Get circuit status to find the last hop fingerprint
            let circuitStatus = try await control.getInfo("circuit-status")
            // Find a BUILT circuit
            let lines = circuitStatus.components(separatedBy: .newlines)
                .filter { $0.contains("BUILT") }

            // Extract last hop from first BUILT circuit
            guard let firstBuilt = lines.first else { return }
            let parts = firstBuilt.components(separatedBy: .whitespaces)
            guard parts.count >= 3 else { return }
            let nodePath = parts[2]
            guard let fp = TorParser.lastHopFingerprint(from: nodePath) else { return }

            // Get router info
            let nsInfo = try await control.getInfo("ns/id/\(fp)")
            guard let ip = TorParser.parseRouterIP(from: nsInfo) else { return }
            let nickname = TorParser.parseRouterNickname(from: nsInfo) ?? fp.prefix(8).description

            // Get country
            let countryResponse = try await control.getInfo("ip-to-country/\(ip)")
            let code = TorParser.parseCountryCode(from: countryResponse) ?? "??"
            let name = TorParser.countryName(for: code)

            exitNode = ExitNode(ip: ip, countryCode: code, countryName: name, nickname: nickname)

        } catch {
            // Non-fatal; exit node display is best-effort
        }
    }

    // MARK: - Public IP

    /// Fetches the apparent public IP, retrying until the IP differs from `oldIP`
    /// (up to 4 attempts, 1.5 s apart). Accepts whatever it gets on the last attempt.
    private func fetchPublicIPRetrying(avoiding oldIP: String?) async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy":  "127.0.0.1",
            "SOCKSPort":   TorManager.socksPort
        ] as [AnyHashable: Any]
        let session = URLSession(configuration: config)
        for attempt in 1...4 {
            if let (data, _) = try? await session.data(from: url),
               let ip = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                publicIP = ip
                if ip != oldIP { return }  // new IP confirmed
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 s
            }
        }
    }

    /// Fetches the apparent public IP.
    /// - When `viaSocks` is true, routes through the local SOCKS proxy so the result
    ///   matches exactly what any app using the proxy sees (i.e. the Tor exit IP).
    /// - When false, bypasses any proxy to return the real machine IP.
    private func fetchPublicIP(viaSocks: Bool = false) async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        let config = URLSessionConfiguration.ephemeral
        if viaSocks {
            config.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy":  "127.0.0.1",
                "SOCKSPort":   TorManager.socksPort
            ] as [AnyHashable: Any]
        } else {
            config.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: config)
        guard let (data, _) = try? await session.data(from: url),
              let ip = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else { return }
        publicIP = ip
    }

    // MARK: - Wait for cookie

    private func waitForCookie(timeout: TimeInterval = 30) async throws {
        let start = Date()
        while true {
            if FileManager.default.fileExists(atPath: manager.cookiePath.path) { return }
            if !manager.isRunning {
                throw TorManagerError.resourceNotFound("Tor process exited before cookie was created")
            }
            if Date().timeIntervalSince(start) > timeout {
                throw TorManagerError.resourceNotFound("control_auth_cookie (timeout)")
            }
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
    }
}
