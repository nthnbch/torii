import Foundation

/// Manages the lifecycle of the bundled Tor process.
/// On first run, copies binaries to ~/Library/Application Support/Torii/ and strips quarantine.
final class TorManager: @unchecked Sendable {

    // MARK: - Constants

    static let socksPort = 9050
    static let controlPort = 9051
    static let bundleVersion = "15.0.11"

    private let appSupport: URL
    private let binDir: URL
    private let ptDir: URL
    private let dataDir: URL
    private var pidFile: URL { dataDir.appendingPathComponent("tor.pid") }

    private var torProcess: Process?
    private var stdoutPipe: Pipe?

    // Callback for log lines from tor stdout
    var onLogLine: ((String) -> Void)?
    // Called when the process exits unexpectedly
    var onProcessExit: ((Int32) -> Void)?

    // MARK: - Init

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Torii")
        appSupport = base
        binDir = base.appendingPathComponent("bin")
        ptDir  = binDir.appendingPathComponent("pluggable_transports")
        dataDir = base.appendingPathComponent("data")
    }

    // MARK: - Setup

    /// Copies bundled resources to Application Support and writes torrc.
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: ptDir,  withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        try copyBundleResource("tor", to: binDir)
        try copyBundleResource("libevent-2.1.7.dylib", to: binDir)
        try copyBundleResource("lyrebird",         to: ptDir,  subdir: "pluggable_transports")
        try copyBundleResource("conjure-client",   to: ptDir,  subdir: "pluggable_transports")
        try copyBundleResource("geoip",            to: dataDir, subdir: "data")
        try copyBundleResource("geoip6",           to: dataDir, subdir: "data")

        let torBin      = binDir.appendingPathComponent("tor")
        let libeventLib = binDir.appendingPathComponent("libevent-2.1.7.dylib")
        let lyrebirdBin = ptDir.appendingPathComponent("lyrebird")
        let conjureBin  = ptDir.appendingPathComponent("conjure-client")

        try makeExecutable(torBin)
        try makeExecutable(lyrebirdBin)
        try makeExecutable(conjureBin)

        // Strip quarantine AND ad-hoc codesign all binaries+dylibs so Gatekeeper doesn't block them
        for bin in [torBin, libeventLib, lyrebirdBin, conjureBin] {
            stripQuarantine(bin)
            adHocSign(bin)
        }

        try writeTorrc()
    }

    // MARK: - System Proxy

    /// Enable macOS system-wide SOCKS proxy pointing to 127.0.0.1:9050 for all active services.
    func enableSystemProxy() {
        for service in activeNetworkServices() {
            run("/usr/sbin/networksetup", args: ["-setsocksfirewallproxy", service,
                                                  "127.0.0.1", "\(TorManager.socksPort)"])
            run("/usr/sbin/networksetup", args: ["-setsocksfirewallproxystate", service, "on"])
        }
    }

    /// Disable the SOCKS proxy on all active services.
    func disableSystemProxy() {
        for service in activeNetworkServices() {
            run("/usr/sbin/networksetup", args: ["-setsocksfirewallproxystate", service, "off"])
        }
    }

    private func activeNetworkServices() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // First line is a warning ("An asterisk (*) denotes…"), skip it
        return output.components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @discardableResult
    private func run(_ path: String, args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - Start / Stop

    func start() throws {
        try prepare()
        killOrphanIfNeeded()

        let proc = Process()
        proc.executableURL = binDir.appendingPathComponent("tor")
        proc.arguments = ["-f", torrcPath.path]

        // Provide DYLD_LIBRARY_PATH so tor finds libevent
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = binDir.path
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe
        stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self?.onLogLine?(line)
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.onProcessExit?(p.terminationStatus)
            }
        }

        try proc.run()
        torProcess = proc
    }

    /// Kill any previously-orphaned tor process we recorded in the pid file.
    private func killOrphanIfNeeded() {
        guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr), pid > 1 else { return }
        kill(pid, SIGTERM)
        // Give it up to 2s to terminate, then SIGKILL
        var waited = 0
        while kill(pid, 0) == 0 && waited < 20 {
            usleep(100_000)   // 100ms
            waited += 1
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    func stop() {
        guard let proc = torProcess, proc.isRunning else { return }
        proc.terminate()
        // Give it a moment to clean up
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
        torProcess = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
    }

    var isRunning: Bool { torProcess?.isRunning == true }

    // MARK: - Auth Cookie

    var cookiePath: URL {
        dataDir.appendingPathComponent("control_auth_cookie")
    }

    func readAuthCookie() throws -> Data {
        try Data(contentsOf: cookiePath)
    }

    // MARK: - Private helpers

    private var torrcPath: URL { appSupport.appendingPathComponent("torrc") }

    private func writeTorrc() throws {
        let geoip  = dataDir.appendingPathComponent("geoip").path
        let geoip6 = dataDir.appendingPathComponent("geoip6").path
        let lyrebird     = ptDir.appendingPathComponent("lyrebird").path
        let conjure      = ptDir.appendingPathComponent("conjure-client").path

        let torrc = """
SOCKSPort \(TorManager.socksPort)
ControlPort \(TorManager.controlPort)
CookieAuthentication 1
DataDirectory \(dataDir.path)
GeoIPFile \(geoip)
GeoIPv6File \(geoip6)
PidFile \(pidFile.path)
Log notice stdout
AvoidDiskWrites 1
ClientTransportPlugin meek_lite,obfs2,obfs3,obfs4,scramblesuit,webtunnel exec \(lyrebird)
ClientTransportPlugin snowflake exec \(lyrebird)
ClientTransportPlugin conjure exec \(conjure) -registerURL https://registration.refraction.network/api
"""
        try torrc.write(to: torrcPath, atomically: true, encoding: .utf8)
    }

    private func copyBundleResource(_ name: String, to dir: URL, subdir: String? = nil) throws {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(name)

        // If file already exists and has same size, skip
        let bundle = Bundle.main
        var srcURL: URL?

        if let subdir = subdir {
            srcURL = bundle.url(forResource: name, withExtension: nil,
                                subdirectory: subdir)
        } else {
            srcURL = bundle.url(forResource: name, withExtension: nil)
        }

        guard let src = srcURL else {
            throw TorManagerError.resourceNotFound(name)
        }

        // Always overwrite to ensure we have the latest binary from the bundle
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        try fm.copyItem(at: src, to: dest)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func stripQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-cr", url.path]   // remove ALL extended attributes recursively
        try? p.run()
        p.waitUntilExit()
    }

    private func adHocSign(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Errors

enum TorManagerError: LocalizedError {
    case resourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Tor resource not found in app bundle: \(name)"
        }
    }
}
