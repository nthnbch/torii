import Foundation

// MARK: - Connection Status

enum TorConnectionStatus: String, Equatable {
    case disconnected = "Disconnected"
    case connecting   = "Connecting…"
    case connected    = "Connected"
    case error        = "Error"

    var isActive: Bool { self == .connecting || self == .connected }
}

// MARK: - Exit Node

struct ExitNode: Equatable {
    let ip: String
    let countryCode: String  // ISO 3166-1 alpha-2, e.g. "US"
    let countryName: String
    let nickname: String

    var flagEmoji: String {
        guard countryCode.count == 2 else { return "🌍" }
        let base: UInt32 = 127397
        var result = ""
        for char in countryCode.uppercased().unicodeScalars {
            if let scalar = Unicode.Scalar(base + char.value) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "🌍" : result
    }

    var displayLine: String {
        "\(flagEmoji) \(countryName) — \(ip)"
    }
}

// MARK: - Bandwidth

struct BandwidthSample {
    let bytesRead: Int
    let bytesWritten: Int
    let timestamp: Date

    static func formatted(_ bps: Double) -> String {
        let kbps = bps / 1024
        if kbps < 1024 {
            return String(format: "%.1f KB/s", kbps)
        } else {
            return String(format: "%.2f MB/s", kbps / 1024)
        }
    }
}

// MARK: - Circuits

struct TorCircuit: Identifiable {
    let id: String
    let status: CircuitStatus
    let nodes: [String]   // fingerprints or nicknames

    enum CircuitStatus: String {
        case launched  = "LAUNCHED"
        case built     = "BUILT"
        case extended  = "EXTENDED"
        case failed    = "FAILED"
        case closed    = "CLOSED"
        case unknown
    }
}

// MARK: - Country selection

struct ExitCountry: Identifiable, Hashable {
    let id: String        // ISO alpha-2
    let name: String
    var flag: String {
        let base: UInt32 = 127397
        var result = ""
        for char in id.uppercased().unicodeScalars {
            if let scalar = Unicode.Scalar(base + char.value) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "🌍" : result
    }
    var displayName: String { "\(flag) \(name)" }
}

extension ExitCountry {
    static let any = ExitCountry(id: "", name: "Any country")

    static let commonCountries: [ExitCountry] = [
        ExitCountry(id: "US", name: "United States"),
        ExitCountry(id: "CA", name: "Canada"),
        ExitCountry(id: "GB", name: "United Kingdom"),
        ExitCountry(id: "DE", name: "Germany"),
        ExitCountry(id: "FR", name: "France"),
        ExitCountry(id: "NL", name: "Netherlands"),
        ExitCountry(id: "SE", name: "Sweden"),
        ExitCountry(id: "CH", name: "Switzerland"),
        ExitCountry(id: "NO", name: "Norway"),
        ExitCountry(id: "FI", name: "Finland"),
        ExitCountry(id: "AT", name: "Austria"),
        ExitCountry(id: "JP", name: "Japan"),
        ExitCountry(id: "AU", name: "Australia"),
        ExitCountry(id: "SG", name: "Singapore"),
        ExitCountry(id: "BR", name: "Brazil"),
        ExitCountry(id: "ES", name: "Spain"),
        ExitCountry(id: "IT", name: "Italy"),
        ExitCountry(id: "PL", name: "Poland"),
        ExitCountry(id: "RO", name: "Romania"),
        ExitCountry(id: "CZ", name: "Czech Republic"),
    ]
}
