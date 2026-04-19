import Foundation

extension ConfigService {
    /// Discover hooks dicts contributed by installed plugins.
    /// Returns one entry per plugin that has any hooks defined, in the shape the
    /// settings.json `hooks` value would take (event name -> array of rule dicts).
    ///
    /// Probes three documented manifest layouts in priority order, taking the first match:
    ///   (a) `<versionDir>/hooks/hooks.json` — canonical separate file
    ///   (b) `<versionDir>/.claude-plugin/plugin.json` with a `hooks` field
    ///   (c) `<versionDir>/plugin.json` with a `hooks` field
    ///
    /// In layouts (b) and (c), the `hooks` field may be:
    ///   - an inline object,
    ///   - a string path to a hooks JSON file (relative to the plugin root),
    ///   - an array of such path strings whose event lists are merged.
    func pluginHookDicts() -> [(pluginName: String, hooksDict: [String: Any])] {
        var out: [(String, [String: Any])] = []

        for (plugin, versionDir) in latestPluginVersionDirs() {
            // (a) hooks/hooks.json — the file itself IS the hooks dict.
            let canonicalURL = versionDir
                .appendingPathComponent("hooks")
                .appendingPathComponent("hooks.json")
            if let dict = readJSON(at: canonicalURL) {
                out.append((plugin, dict))
                continue
            }

            // (b) .claude-plugin/plugin.json
            let nestedManifest = versionDir
                .appendingPathComponent(".claude-plugin")
                .appendingPathComponent("plugin.json")
            if let manifest = readJSON(at: nestedManifest),
               let hooks = extractHooksDict(from: manifest, pluginRoot: versionDir) {
                out.append((plugin, hooks))
                continue
            }

            // (c) plugin.json at the version dir root (e.g. pyright)
            let flatManifest = versionDir.appendingPathComponent("plugin.json")
            if let manifest = readJSON(at: flatManifest),
               let hooks = extractHooksDict(from: manifest, pluginRoot: versionDir) {
                out.append((plugin, hooks))
            }
        }

        return out
    }

    private func extractHooksDict(from manifest: [String: Any], pluginRoot: URL) -> [String: Any]? {
        guard let raw = manifest["hooks"] else { return nil }

        if let inline = raw as? [String: Any] {
            return inline
        }
        if let pathStr = raw as? String {
            return readJSON(at: pluginRoot.appendingPathComponent(pathStr))
        }
        if let paths = raw as? [String] {
            var merged: [String: Any] = [:]
            for path in paths {
                guard let dict = readJSON(at: pluginRoot.appendingPathComponent(path)) else { continue }
                for (event, rules) in dict {
                    if var existing = merged[event] as? [Any], let new = rules as? [Any] {
                        existing.append(contentsOf: new)
                        merged[event] = existing
                    } else {
                        merged[event] = rules
                    }
                }
            }
            return merged.isEmpty ? nil : merged
        }
        return nil
    }
}
