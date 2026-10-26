import Foundation

enum ChildKind {
    case directory, file, symlink
}

struct DirectoryChild {
    let name: String
    let kind: ChildKind
}

/// Reads directories with opendir/readdir: one system call stream per folder and
/// no per-file URL or resource-value objects, unlike `FileManager.enumerator`.
enum DirectoryReader {
    /// Children of `path`, or nil when it is not a readable directory.
    static func children(of path: String) -> [DirectoryChild]? {
        guard let handle = opendir(path) else { return nil }
        defer { closedir(handle) }
        var result: [DirectoryChild] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let kind: ChildKind
            switch Int32(entry.pointee.d_type) {
            case DT_DIR: kind = .directory
            case DT_LNK: kind = .symlink
            case DT_UNKNOWN: kind = lstatKind(Paths.join(path, name))
            default: kind = .file
            }
            result.append(DirectoryChild(name: name, kind: kind))
        }
        return result
    }

    private static func lstatKind(_ path: String) -> ChildKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .file }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .file
        }
    }

    /// Only folders whose name has an extension can be packages, so the costly
    /// Launch Services check runs for a small minority of folders.
    static func isPackage(name: String, path: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return false }
        let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage == true
    }
}
