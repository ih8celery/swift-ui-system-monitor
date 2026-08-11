import Foundation

/// A project is identified by the repository root it lives in, so nothing machine-specific is ever
/// compiled into the app and the same code works on anyone's Mac.
struct ProjectIdentity: Hashable {
    let rootPath: String

    var displayName: String {
        URL(fileURLWithPath: rootPath).lastPathComponent
    }
}

/// Works out which project a process belongs to by walking up from paths in its arguments to the
/// nearest enclosing Git repository.
///
/// This is inference, not knowledge: it can only see projects a process names on its command line.
/// Work it cannot place stays visibly unattributed rather than being guessed at.
final class ProjectResolver {
    /// A build tree can be deep, but an unbounded walk on a pathological path is worse than a miss.
    static let maximumWalkDepth = 12

    private let homeDirectory: String
    private let isRepository: (String) -> Bool
    /// Every directory visited during a walk remembers its answer, so one Xcode build's twenty
    /// compile jobs share a single climb instead of repeating it twenty times.
    private var repositoryRootByDirectory: [String: String?] = [:]

    init(
        homeDirectory: String = NSHomeDirectory(),
        isRepository: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: "\($0)/.git") }
    ) {
        self.homeDirectory = homeDirectory
        self.isRepository = isRepository
    }

    func project(forArgs args: String) -> ProjectIdentity? {
        for token in Self.absolutePathTokens(in: args) {
            if let root = repositoryRoot(forPath: token) {
                return ProjectIdentity(rootPath: root)
            }
        }
        return nil
    }

    func repositoryRoot(forPath path: String) -> String? {
        if let cached = repositoryRootByDirectory[path] { return cached }

        var visited: [String] = []
        var directory = path
        var depth = 0

        while depth < Self.maximumWalkDepth {
            if let cached = repositoryRootByDirectory[directory] {
                return remember(cached, for: visited)
            }
            // The home directory is a wall the walk never tests and never crosses: a dotfiles
            // repository there would otherwise swallow every process on the machine.
            if directory == homeDirectory || directory == "/" || directory.isEmpty {
                return remember(nil, for: visited)
            }
            if isRepository(directory) {
                return remember(directory, for: visited + [directory])
            }
            visited.append(directory)
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }

        return remember(nil, for: visited)
    }

    private func remember(_ root: String?, for directories: [String]) -> String? {
        for directory in directories {
            repositoryRootByDirectory[directory] = root
        }
        return root
    }

    /// Absolute paths mentioned anywhere in the command line, including ones attached to a flag as
    /// `--flag=/path`. Quoted paths containing spaces are not recovered — that is a miss, and a
    /// miss shows up as unattributed work rather than as a wrong project.
    static func absolutePathTokens(in args: String) -> [String] {
        args
            .split(whereSeparator: \.isWhitespace)
            .flatMap { $0.split(separator: "=") }
            .map(String.init)
            .filter { $0.hasPrefix("/") && $0.count > 1 }
    }
}
