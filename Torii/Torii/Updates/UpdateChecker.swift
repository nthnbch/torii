import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {

    @Published var updateAvailable: String? = nil
    @Published var latestVersion: String? = nil

    private let currentVersion = TorManager.bundleVersion
    private let indexURL = URL(string: "https://dist.torproject.org/torbrowser/")!

    func checkForUpdates() async {
        guard let version = await fetchLatestVersion() else { return }
        latestVersion = version
        if isNewer(version, than: currentVersion) {
            updateAvailable = version
        }
    }

    // MARK: - Private

    private func fetchLatestVersion() async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: indexURL),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // Parse directory listing for version numbers like "15.0.12/"
        // Lines contain: href="15.0.12/"
        let pattern = #"href="(\d+\.\d+\.\d+(?:\.\d+)?)\/""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsString = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        let versions: [String] = matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return nsString.substring(with: range)
        }

        return versions
            .filter { isValidVersion($0) }
            .sorted { compareVersions($0, $1) > 0 }
            .first
    }

    private func isValidVersion(_ v: String) -> Bool {
        let parts = v.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 3
    }

    /// Returns positive if a > b, negative if a < b, 0 if equal
    private func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let len = max(aParts.count, bParts.count)
        for i in 0..<len {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av - bv }
        }
        return 0
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        compareVersions(candidate, current) > 0
    }
}
