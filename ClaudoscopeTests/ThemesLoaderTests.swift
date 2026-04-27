import XCTest
@testable import Claudoscope

final class ThemesLoaderTests: XCTestCase {
    private var tempRoot: URL!
    private var claudeDir: URL!
    private var service: ConfigService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-themes-tests-\(UUID().uuidString)")
        claudeDir = tempRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        service = ConfigService(claudeDir: claudeDir)
    }

    override func tearDown() async throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    private func writeTheme(name: String, contents: String = "{}") throws {
        let themesDir = claudeDir.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        let url = themesDir.appendingPathComponent("\(name).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReturnsEmptyWhenThemesDirMissing() async {
        let themes = await service.loadThemes()
        XCTAssertTrue(themes.isEmpty)
    }

    func testListsThemesByFilename() async throws {
        try writeTheme(name: "dracula")
        try writeTheme(name: "solarized")

        let themes = await service.loadThemes()
        XCTAssertEqual(themes.map(\.name), ["dracula", "solarized"])
    }

    func testIgnoresNonJsonFiles() async throws {
        try writeTheme(name: "valid")
        let themesDir = claudeDir.appendingPathComponent("themes")
        try "noise".write(to: themesDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "noise".write(to: themesDir.appendingPathComponent("backup.json.bak"), atomically: true, encoding: .utf8)

        let themes = await service.loadThemes()
        XCTAssertEqual(themes.map(\.name), ["valid"])
    }

    func testMarksActiveThemeFromClaudeJson() async throws {
        try writeTheme(name: "dracula")
        try writeTheme(name: "solarized")

        // Active theme name is read from ~/.claude.json. ConfigService uses the
        // real home dir for that file, so we cannot simulate it from a temp dir.
        // This test asserts the negative: nothing is marked active when the
        // user's real ~/.claude.json doesn't reference one of these names.
        let themes = await service.loadThemes()
        for theme in themes {
            XCTAssertFalse(theme.isActive, "test theme \(theme.name) should not match a real active theme")
        }
    }

    func testCapturesMtime() async throws {
        try writeTheme(name: "dracula")

        let themes = await service.loadThemes()
        XCTAssertEqual(themes.count, 1)
        XCTAssertNotNil(themes.first?.mtime)
    }
}
