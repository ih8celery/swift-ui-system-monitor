import Foundation
import SystemBarKit

/// One fake answer: when a plugin runs exactly this path with exactly these arguments.
struct CannedReply: Equatable, Sendable {
    let path: String
    let arguments: [String]
    let output: String
    let error: String
    let status: Int32
}

/// The `--replies` file and the runner that answers from it. Parsed as strictly as plugins.json:
/// an unknown key or a wrong type names its place, so a typo never quietly runs a real command.
enum CannedReplies {
    /// What a command with no canned reply exits with: the shell's "command not found".
    static let missingStatus: Int32 = 127

    private static let topLevelKeys: Set<String> = ["replies"]
    private static let replyKeys: Set<String> = ["path", "arguments", "output", "error", "status"]

    static func parse(_ data: Data) -> Result<[CannedReply], PreviewInputError> {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(PreviewInputError(description: "the replies file is not valid JSON"))
        }
        guard let object = root as? [String: Any] else {
            return .failure(PreviewInputError(description: "the replies file must be a JSON object"))
        }
        if let unknown = object.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return .failure(PreviewInputError(description: "the replies file has an unknown key \"\(unknown)\""))
        }
        guard let list = object["replies"] as? [Any] else {
            return .failure(PreviewInputError(description: "the replies file needs \"replies\", a list"))
        }
        var replies: [CannedReply] = []
        for (index, raw) in list.enumerated() {
            switch parseReply(raw, place: "reply \(index + 1)") {
            case .success(let reply):
                if let first = replies.firstIndex(where: { $0.path == reply.path && $0.arguments == reply.arguments }) {
                    return .failure(PreviewInputError(
                        description: "reply \(index + 1) in the replies file repeats the command in reply \(first + 1)"))
                }
                replies.append(reply)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(replies)
    }

    private static func parseReply(_ raw: Any, place: String) -> Result<CannedReply, PreviewInputError> {
        func problem(_ text: String) -> Result<CannedReply, PreviewInputError> {
            .failure(PreviewInputError(description: "\(place) in the replies file \(text)"))
        }
        guard let object = raw as? [String: Any] else { return problem("must be an object") }
        if let unknown = object.keys.sorted().first(where: { !replyKeys.contains($0) }) {
            return problem("has an unknown key \"\(unknown)\"")
        }
        guard let path = object["path"] as? String else { return problem("needs \"path\", a string") }
        guard let arguments = object["arguments"] as? [String] else {
            return problem("needs \"arguments\", a list of strings")
        }
        guard let output = object["output"] as? String else { return problem("needs \"output\", a string") }
        let error = object["error"] ?? ""
        guard let errorText = error as? String else { return problem("has an \"error\" that is not a string") }
        let status = object["status"] ?? NSNumber(value: 0)
        guard !isBoolean(status), let number = status as? NSNumber, number.doubleValue == number.doubleValue.rounded(),
              Double(Int32.min)...Double(Int32.max) ~= number.doubleValue else {
            return problem("has a \"status\" that is not a whole number that fits in 32 bits")
        }
        return .success(CannedReply(path: path, arguments: arguments, output: output, error: errorText, status: number.int32Value))
    }

    /// JSONSerialization hands back `true` as an NSNumber, so it is told apart by its CF type.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// A runner that answers from `replies` and refuses everything else with status 127.
    static func runner(_ replies: [CannedReply]) -> CommandRunner {
        { path, arguments, _, _ in
            if let reply = replies.first(where: { $0.path == path && $0.arguments == arguments }) {
                return CommandOutput(output: reply.output, error: reply.error, status: reply.status, didTimeout: false)
            }
            let line = ([path] + arguments).joined(separator: " ")
            return CommandOutput(output: "", error: "no canned reply for \(line)", status: missingStatus, didTimeout: false)
        }
    }
}
