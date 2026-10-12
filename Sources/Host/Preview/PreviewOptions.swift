import CoreGraphics
import Foundation

/// What `SystemBar --preview ...` was asked to do. Paths are made absolute here, against the
/// folder the command was run from, because the loader only accepts absolute or `~/` paths.
struct PreviewOptions: Equatable {
    enum Output: Equatable {
        case png(URL)
        case window
    }

    static let flag = "--preview"
    /// The popover's size, so a picture shows the tab as the menu bar would.
    static let defaultSize = CGSize(width: 900, height: 680)
    static let usage = """
    usage: SystemBar --preview <bundle> --png <out.png> [--replies <file>] [--settings <file>] [--size <W>x<H>]
           SystemBar --preview <bundle> --window [--replies <file>] [--settings <file>] [--size <W>x<H>]
    """

    let bundlePath: String
    let output: Output
    let repliesURL: URL?
    let settingsURL: URL?
    let size: CGSize

    private static let valueFlags: Set<String> = ["--png", "--replies", "--settings", "--size"]

    /// `arguments` starts with `--preview`, as `CommandLine.arguments.dropFirst()` does.
    static func parse(_ arguments: [String], currentDirectory: String) -> Result<PreviewOptions, PreviewInputError> {
        var words = Array(arguments.drop(while: { $0 == flag }))
        guard let bundle = words.first, !bundle.hasPrefix("--") else {
            return failure("--preview needs the path of a plugin bundle first")
        }
        words.removeFirst()
        var values: [String: String] = [:]
        var wantsWindow = false
        while let word = words.first {
            words.removeFirst()
            if word == "--window" {
                wantsWindow = true
                continue
            }
            guard valueFlags.contains(word) else { return failure("--preview does not know \(word)") }
            guard values[word] == nil else { return failure("\(word) is given twice") }
            guard let value = words.first, !value.hasPrefix("--") else { return failure("\(word) needs a value") }
            words.removeFirst()
            values[word] = value
        }
        let absolute = { (path: String) in Self.absolutePath(path, currentDirectory: currentDirectory) }
        let output: Output
        switch (values["--png"], wantsWindow) {
        case (let png?, false): output = .png(URL(fileURLWithPath: absolute(png)))
        case (nil, true): output = .window
        case (nil, false): return failure("--preview needs --png <file> or --window")
        case (.some, true): return failure("--preview takes --png or --window, not both")
        }
        var size = defaultSize
        if let text = values["--size"] {
            guard let parsed = parseSize(text) else { return failure("--size must look like 900x680, not \(text)") }
            size = parsed
        }
        return .success(PreviewOptions(
            bundlePath: absolute(bundle),
            output: output,
            repliesURL: values["--replies"].map { URL(fileURLWithPath: absolute($0)) },
            settingsURL: values["--settings"].map { URL(fileURLWithPath: absolute($0)) },
            size: size
        ))
    }

    private static func failure(_ text: String) -> Result<PreviewOptions, PreviewInputError> {
        .failure(PreviewInputError(description: text))
    }

    private static func absolutePath(_ path: String, currentDirectory: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~/") { return path }
        return URL(fileURLWithPath: currentDirectory).appendingPathComponent(path).standardizedFileURL.path
    }

    private static func parseSize(_ text: String) -> CGSize? {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
