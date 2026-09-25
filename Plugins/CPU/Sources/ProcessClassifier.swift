import Foundation

/// Best-guess, plain-english identity for a process group. Prefixed "Likely:" in
/// the UI so a wrong guess reads as a guess. Rules are first-match-wins over the
/// group's exe paths, args, and 2-hop parent chain; the fallback never asserts
/// anything false — it just restates the raw parent and path.
enum ProcessClassifier {
    static func likelyLabel(for rows: [ProcessDetail]) -> String {
        guard let first = rows.first else { return "No live processes" }

        let paths = rows.map { $0.path.lowercased() }
        let args = rows.map { $0.command.lowercased() }
        // 2-hop parent chain names across every PID in the group.
        let ancestors = rows.flatMap { [$0.parentName, $0.grandparentName] }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        func anyPath(_ needle: String) -> Bool { paths.contains { $0.contains(needle) } }
        func anyArg(_ needle: String) -> Bool { args.contains { $0.contains(needle) } }
        func anyAncestor(_ needles: [String]) -> Bool {
            ancestors.contains { name in needles.contains { name.contains($0) } }
        }

        // 1. Xcode build.
        if anyPath("xcode.app") || anyPath(".xctoolchain") || anyPath("/developer/toolchains")
            || anyAncestor(["xcode", "xcodebuild"]) {
            let count = rows.count
            return "Xcode compiling (\(count) job\(count == 1 ? "" : "s"))"
        }

        // 2. MCP server (args mention mcp, parent is Claude or node).
        if anyArg("mcp"), let host = ancestorMatching(rows, ["claude", "node"]) {
            return "MCP server started by \(host)"
        }

        // 3. Browser jobs (browser parent + renderer/gpu/utility worker).
        if let browser = browserAncestor(rows),
           anyArg("--type=renderer") || anyArg("--type=gpu") || anyArg("--type=utility") {
            return "\(browser) page/tab work"
        }

        // 4. Node / JS tooling.
        if anyAncestor(["node", "npm", "pnpm", "yarn", "vite", "esbuild", "deno", "bun"]) {
            return "Node build tooling"
        }

        // 5. macOS system service (strong signal is the exe path, not just launchd).
        if anyPath("/usr/libexec") || anyPath("/system/") || anyPath("/usr/sbin") {
            return "macOS system service"
        }

        // 6. Terminal job (ppid chain hits a shell / terminal app).
        if anyAncestor(["tmux", "zsh", "bash", "fish", "terminal", "iterm", "login"]) {
            return "Started from your terminal"
        }

        // 7. Honest fallback.
        return "Started by \(first.parentName) — \(first.path)"
    }

    /// The original-cased ancestor name matching one of the needles (for the label).
    private static func ancestorMatching(_ rows: [ProcessDetail], _ needles: [String]) -> String? {
        for row in rows {
            for name in [row.parentName, row.grandparentName] where !name.isEmpty {
                let lower = name.lowercased()
                if needles.contains(where: { lower.contains($0) }) { return name }
            }
        }
        return nil
    }

    /// A friendly browser name if any ancestor is a known browser.
    private static func browserAncestor(_ rows: [ProcessDetail]) -> String? {
        let known: [(needle: String, label: String)] = [
            ("chrome", "Chrome"), ("safari", "Safari"), ("firefox", "Firefox"),
            ("brave", "Brave"), ("microsoft edge", "Edge"), ("arc", "Arc")
        ]
        let ancestors = rows.flatMap { [$0.parentName, $0.grandparentName] }.map { $0.lowercased() }
        for entry in known where ancestors.contains(where: { $0.contains(entry.needle) }) {
            return entry.label
        }
        return nil
    }
}
