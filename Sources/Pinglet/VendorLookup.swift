import Foundation

final class VendorLookup {
    private var vendors: [String: String] = [:]

    init() {
        loadFromBundle()
    }

    func vendorName(for mac: String) -> String? {
        let oui = mac
            .uppercased()
            .replacingOccurrences(of: ":", with: "")
            .prefix(6)

        guard !oui.isEmpty else { return nil }
        return vendors[String(oui)]
    }

    private func loadFromBundle() {
        guard let url = Bundle.module.url(forResource: "oui", withExtension: "json") else { return }
        guard let data = try? Data(contentsOf: url) else { return }

        if let map = try? JSONDecoder().decode([String: String].self, from: data) {
            vendors = map.reduce(into: [:]) { result, entry in
                let key = entry.key
                    .uppercased()
                    .replacingOccurrences(of: ":", with: "")
                result[key] = entry.value
            }
        }
    }
}
