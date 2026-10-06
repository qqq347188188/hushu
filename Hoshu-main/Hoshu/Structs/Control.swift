import Foundation

struct Control: Identifiable, Codable {
    let id: UUID
    let package: String
    let name: String
    let version: String
    let architecture: String
    let packageDescription: String
    let maintainer: String
    let author: String
    let section: String
    let depends: [String]
    let conflicts: [String]
    let icon: String
    let depiction: String
    let homepage: URL?
    let installedSize: Int
    let isDetectedAsRootless: Bool

    private var fields: [String: String] {
        return [
            "package": package,
            "name": name,
            "version": version,
            "architecture": architecture,
            "description": packageDescription,
            "maintainer": maintainer,
            "author": author,
            "section": section,
            "depends": depends.joined(separator: ", "),
            "conflicts": conflicts.joined(separator: ", "),
            "icon": icon,
            "depiction": depiction,
            "homepage": homepage?.absoluteString ?? "",
            "installed-size": "\(installedSize)",
        ]
    }

    func getValue(forField field: String) -> String? {
        fields[field.lowercased()]
    }
}
