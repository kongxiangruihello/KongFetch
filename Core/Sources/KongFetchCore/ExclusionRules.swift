import Foundation

/// What the name index leaves out. Unlike 3.2, nothing is hard-coded: a folder
/// the user happens to call `build` or `Library` is indexed unless listed here.
public struct ExclusionRules: Codable, Equatable, Sendable {
    /// Exact folders skipped with everything inside (canonicalized when compiled).
    public var excludedPaths: [String]
    /// File or folder names skipped wherever they appear.
    public var excludedNames: [String]
    /// Index names starting with "." (3.2 always skipped them).
    public var includeHidden: Bool
    /// Descend into packages such as `.app` or `.photoslibrary` (3.2 never did).
    public var indexPackageContents: Bool

    public init(excludedPaths: [String] = [], excludedNames: [String] = [], includeHidden: Bool = false, indexPackageContents: Bool = false) {
        self.excludedPaths = excludedPaths
        self.excludedNames = excludedNames
        self.includeHidden = includeHidden
        self.indexPackageContents = indexPackageContents
    }

    /// Recommended defaults: skip `~/Library` by exact path and only names that are
    /// never user documents. Hidden names and package contents stay out, as in 3.2.
    public static func standard(home: String = NSHomeDirectory()) -> ExclusionRules {
        ExclusionRules(
            excludedPaths: [Paths.join(home, "Library")],
            excludedNames: ["node_modules", ".git", "DerivedData", ".Trash"],
            includeHidden: false,
            indexPackageContents: false
        )
    }

    /// 3.2 behaviour, kept for comparisons: these names were skipped at any depth.
    public static let legacy32 = ExclusionRules(
        excludedPaths: [],
        excludedNames: ["node_modules", "Library", ".git", "build", "DerivedData"],
        includeHidden: false,
        indexPackageContents: false
    )

    func compiled() -> CompiledExclusions {
        CompiledExclusions(
            paths: Set(excludedPaths.map(Paths.canonical)),
            names: Set(excludedNames),
            includeHidden: includeHidden,
            indexPackageContents: indexPackageContents
        )
    }
}

struct CompiledExclusions {
    let paths: Set<String>
    let names: Set<String>
    let includeHidden: Bool
    let indexPackageContents: Bool

    @inline(__always)
    func skips(name: String, path: String) -> Bool {
        if !includeHidden && name.hasPrefix(".") { return true }
        if names.contains(name) { return true }
        return !paths.isEmpty && paths.contains(path)
    }
}
