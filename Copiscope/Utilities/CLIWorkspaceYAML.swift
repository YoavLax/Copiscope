import Foundation

/// Parses the `workspace.yaml` file written by the GitHub Copilot CLI.
/// The file uses a simple `key: value` line format.
struct CLIWorkspaceYAML: Sendable {
    let id: String
    let cwd: String
    let name: String?
    let summary: String?
    let createdAt: String?
    let updatedAt: String?

    static func parse(from url: URL) -> CLIWorkspaceYAML? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var dict: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            guard let colonRange = line.range(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                dict[key] = value
            }
        }
        guard let id = dict["id"].map({ $0 }), !id.isEmpty,
              let cwd = dict["cwd"].map({ $0 }), !cwd.isEmpty
        else { return nil }
        return CLIWorkspaceYAML(
            id: id,
            cwd: cwd,
            name: dict["name"].flatMap { $0.isEmpty ? nil : $0 },
            summary: dict["summary"].flatMap { $0.isEmpty ? nil : $0 },
            createdAt: dict["created_at"],
            updatedAt: dict["updated_at"]
        )
    }
}
