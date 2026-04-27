import Foundation

extension ConfigService {
    /// Enumerate `~/.claude/themes/*.json`. Schema is intentionally unparsed in v1
    /// (Claude Code 2.1.118 introduced the directory but did not document the file
    /// shape). Returns filename + mtime + active flag, sorted by name. Empty array
    /// if the directory does not exist.
    func loadThemes() -> [ThemeFile] {
        let themesDir = claudeDir.appendingPathComponent("themes")
        guard fm.fileExists(atPath: themesDir.path) else { return [] }

        let activeName = activeThemeName()

        guard let entries = try? fm.contentsOfDirectory(
            at: themesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let themes: [ThemeFile] = entries.compactMap { url in
            guard url.pathExtension.lowercased() == "json" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return ThemeFile(
                name: name,
                path: url.path,
                mtime: mtime,
                isActive: name == activeName
            )
        }

        return themes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Read the active theme name from `~/.claude.json`'s top-level `theme` field.
    /// Falls back to nil if the file or field is missing.
    private func activeThemeName() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        guard let json = readJSON(at: homeDir.appendingPathComponent(".claude.json")) else {
            return nil
        }
        return json["theme"] as? String
    }
}
