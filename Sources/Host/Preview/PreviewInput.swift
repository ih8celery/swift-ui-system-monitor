import Foundation

/// A problem with what was typed or with a file the preview was pointed at: one sentence a
/// person can act on.
struct PreviewInputError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// What `SystemBar --preview` exits with.
enum PreviewExit {
    static let ok: Int32 = 0
    /// The bundle did not load, or its picture could not be drawn or saved.
    static let failed: Int32 = 1
    /// The command line, the settings file or the replies file was wrong.
    static let badInput: Int32 = 2
}
