import Foundation

extension ConfigService {
    /// Scan global commands from ~/.claude/commands/ AND plugin commands.
    func loadCommands() -> [CommandEntry] {
        var entries: [CommandEntry] = []

        // 1. Global commands from ~/.claude/commands/
        let commandsDir = claudeDir.appendingPathComponent("commands")
        if let fileNames = try? fm.contentsOfDirectory(atPath: commandsDir.path) {
            for fileName in fileNames where fileName.hasSuffix(".md") {
                if let entry = readCommandFile(
                    url: commandsDir.appendingPathComponent(fileName),
                    name: String(fileName.dropLast(3))
                ) {
                    entries.append(entry)
                }
            }
        }

        // 2. Plugin commands from ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/commands/
        for (plugin, versionDir) in latestPluginVersionDirs() {
            let cmdsDir = versionDir.appendingPathComponent("commands")
            if let cmdFiles = try? fm.contentsOfDirectory(atPath: cmdsDir.path) {
                for cmdFile in cmdFiles where cmdFile.hasSuffix(".md") {
                    let cmdName = String(cmdFile.dropLast(3))
                    if let entry = readCommandFile(
                        url: cmdsDir.appendingPathComponent(cmdFile),
                        name: cmdName,
                        pluginName: plugin
                    ) {
                        entries.append(entry)
                    }
                }
            }
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return entries
    }

    func readCommandFile(url: URL, name: String, pluginName: String? = nil) -> CommandEntry? {
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let sizeBytes = (attrs?[.size] as? Int) ?? data.count
        let description = extractDescription(from: content)

        let displayName = pluginName != nil ? "\(name) (\(pluginName!))" : name

        return CommandEntry(
            name: displayName,
            description: description,
            content: content,
            sizeBytes: sizeBytes
        )
    }

    func extractDescription(from content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("---") { continue }
            if trimmed.hasPrefix("# ") {
                let desc = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return desc.isEmpty ? nil : desc
            }
            return trimmed
        }
        return nil
    }

    /// Resolve latest plugin version directories.
    /// Picks the most recently modified version dir, since version dirnames may be
    /// non-semver (e.g. content-hashes like "7ed523140f50", or "unknown") and
    /// lexicographic sort would mis-pick them or order "1.10.0" before "1.9.0".
    func latestPluginVersionDirs() -> [(plugin: String, versionDir: URL)] {
        let cacheDir = claudeDir
            .appendingPathComponent("plugins")
            .appendingPathComponent("cache")

        var results: [(String, URL)] = []

        guard let marketplaces = try? fm.contentsOfDirectory(atPath: cacheDir.path) else {
            return results
        }

        for marketplace in marketplaces {
            let marketplaceDir = cacheDir.appendingPathComponent(marketplace)
            guard let plugins = try? fm.contentsOfDirectory(atPath: marketplaceDir.path) else { continue }

            for plugin in plugins {
                let pluginDir = marketplaceDir.appendingPathComponent(plugin)
                guard let versions = try? fm.contentsOfDirectory(atPath: pluginDir.path),
                      !versions.isEmpty else { continue }

                let dated: [(URL, Date)] = versions.compactMap { version in
                    let url = pluginDir.appendingPathComponent(version)
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                    return (url, mtime)
                }
                guard let latest = dated.max(by: { $0.1 < $1.1 })?.0 else { continue }
                results.append((plugin, latest))
            }
        }

        return results
    }
}
