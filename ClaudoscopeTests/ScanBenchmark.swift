import XCTest
@testable import Claudoscope

/// Cold-cache scan benchmark for the SessionParser single-pass refactor.
/// Disabled by default; enable with `CLAUDOSCOPE_BENCH=1`. Performs one timed
/// run of `ProjectScanner.scan()` against the real `~/.claude/projects` tree
/// and prints `BENCH_MS=<value>` to stdout. The driver script in
/// `scripts/bench-scan.sh` purges the page cache between invocations and
/// repeats N times per version.
final class ScanBenchmark: XCTestCase {
    func testColdScan() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH"] == "1" else {
            throw XCTSkip("set CLAUDOSCOPE_BENCH=1 to enable")
        }
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("projects").path) else {
            throw XCTSkip("no real ~/.claude/projects directory")
        }
        let parser = SessionParser()
        let pricing = PricingTables.anthropic
        let scanner = ProjectScanner(claudeDir: claudeDir, parser: parser, pricingTable: pricing)

        let t0 = CFAbsoluteTimeGetCurrent()
        let (projects, sessions) = await scanner.scan()
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let totalSessions = sessions.values.reduce(0) { $0 + $1.count }
        print(String(format: "BENCH_MS=%.1f projects=%d sessions=%d",
                     dt * 1000, projects.count, totalSessions))
    }
}
