import Foundation

/// Stateless parsers for Tor control protocol responses and events.
enum TorParser {

    // MARK: - Bandwidth event
    // "650 BW 1234 5678"  (read, written in bytes)

    static func parseBWEvent(_ line: String) -> (read: Int, written: Int)? {
        // "650 BW <read> <written>"
        let parts = line.components(separatedBy: .whitespaces)
        guard parts.count >= 4,
              parts[0] == "650",
              parts[1] == "BW",
              let r = Int(parts[2]),
              let w = Int(parts[3]) else { return nil }
        return (r, w)
    }

    // MARK: - Bootstrap status
    // "650 STATUS_CLIENT NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY=Done"

    static func parseBootstrapProgress(_ line: String) -> Int? {
        guard line.contains("BOOTSTRAP") else { return nil }
        if let range = line.range(of: "PROGRESS=") {
            let after = line[range.upperBound...]
            let digits = after.prefix(while: \.isNumber)
            return Int(digits)
        }
        return nil
    }

    static func parseBootstrapSummary(_ line: String) -> String? {
        guard line.contains("BOOTSTRAP") else { return nil }
        if let range = line.range(of: "SUMMARY=") {
            var rest = String(line[range.upperBound...])
            // Strip surrounding quotes if present
            if rest.hasPrefix("\"") { rest.removeFirst() }
            if let end = rest.firstIndex(of: "\"") { rest = String(rest[..<end]) }
            // Strip trailing key=value pairs
            if let space = rest.firstIndex(of: " ") { rest = String(rest[..<space]) }
            return rest
        }
        return nil
    }

    // MARK: - Circuit status
    // GETINFO circuit-status response lines:
    // "250+circuit-status="
    // "123 BUILT $FP1~Name1,$FP2~Name2 ..."
    // "."
    // "250 OK"

    static func parseCircuits(from lines: [String]) -> [TorCircuit] {
        var circuits: [TorCircuit] = []
        for line in lines {
            let parts = line.components(separatedBy: .whitespaces)
            guard parts.count >= 3,
                  let _ = Int(parts[0]) else { continue }

            let status: TorCircuit.CircuitStatus = TorCircuit.CircuitStatus(rawValue: parts[1]) ?? .unknown
            let nodePart = parts[2]
            let nodes = nodePart.components(separatedBy: ",")
                .map { node -> String in
                    // "$FP~Nickname" → "Nickname" or fingerprint
                    if let tilde = node.firstIndex(of: "~") {
                        return String(node[node.index(after: tilde)...])
                    }
                    return node.hasPrefix("$") ? String(node.dropFirst()) : node
                }
            circuits.append(TorCircuit(id: parts[0], status: status, nodes: nodes))
        }
        return circuits
    }

    // MARK: - Router info (ns/id or ns/name)
    // Lines from GETINFO ns/id/<fp>:
    // "r Nickname <base64fp> ... <IP> <ORPort> <DirPort>"
    // "s <flags>"
    // "..."

    static func parseRouterIP(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces)
            // "r" line: r Nickname Base64ID Base64Digest date time IP ORPort DirPort
            if parts.count >= 9, parts[0] == "r" {
                return parts[6]
            }
        }
        return nil
    }

    static func parseRouterNickname(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces)
            if parts.count >= 2, parts[0] == "r" {
                return parts[1]
            }
        }
        return nil
    }

    // MARK: - ip-to-country
    // GETINFO ip-to-country/<ip>  →  "250-ip-to-country/1.2.3.4=US"

    static func parseCountryCode(from response: String) -> String? {
        // response is the value part after "="
        let code = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
        return code.uppercased()
    }

    // MARK: - Version
    // GETINFO version  →  "0.4.8.12"

    static func parseVersion(from text: String) -> String? {
        let clean = text
            .replacingOccurrences(of: "Tor ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip status tag like " (git-xxx)"
        if let paren = clean.firstIndex(of: "(") {
            return String(clean[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return clean.isEmpty ? nil : clean
    }

    /// Returns true for a realtime CIRC BUILT event that represents a full
    /// 3-hop exit circuit (vs a 2-hop internal circuit).
    /// Event format: "650 CIRC <id> BUILT $FP1~N1,$FP2~N2,$FP3~N3 ..."
    static func isExitCircuitBuilt(_ line: String) -> Bool {
        guard line.contains("CIRC"), line.contains("BUILT") else { return false }
        let tokens = line.components(separatedBy: .whitespaces)
        guard let pathToken = tokens.first(where: { $0.hasPrefix("$") }) else { return false }
        return pathToken.filter({ $0 == "," }).count == 2  // 2 commas = 3 hops
    }

    // MARK: - Circuit last hop fingerprint
    // From circuit-status node list "$FP1~Name1,$FP2~Name2", returns the last fingerprint

    static func lastHopFingerprint(from nodePath: String) -> String? {
        let nodes = nodePath.components(separatedBy: ",")
        guard let last = nodes.last else { return nil }
        let fp = last.components(separatedBy: "~").first ?? last
        return fp.hasPrefix("$") ? String(fp.dropFirst()) : fp
    }
}

// MARK: - Country name lookup

extension TorParser {
    static func countryName(for code: String) -> String {
        let locale = Locale(identifier: "en_US")
        return locale.localizedString(forRegionCode: code) ?? code
    }
}
