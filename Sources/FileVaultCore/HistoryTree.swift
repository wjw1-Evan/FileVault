import Foundation

/// One entry in a commit's COMPLETE file listing (git ls-tree -r -z).
///
/// The history window's "changed files" list only shows what a commit touched;
/// this models the whole tree as it existed at that commit, so a user can also
/// preview / restore files that commit did not modify.
public struct CommitTreeEntry: Equatable, Sendable {
    /// What the entry is, derived from git's mode field.
    public enum Kind: String, Equatable, Sendable {
        case file
        case symlink
        case submodule
        case other
    }

    /// Repo-relative path with "/" separators (raw UTF-8, never quoted).
    public let path: String
    /// Git mode: 100644, 100755, 120000, 160000, ...
    public let mode: String

    public init(path: String, mode: String) {
        self.path = path
        self.mode = mode
    }

    public var kind: Kind {
        switch mode {
        case "120000": return .symlink
        case "160000": return .submodule
        case "100644", "100755": return .file
        default: return .other
        }
    }

    /// Display name without directories.
    public var name: String { (path as NSString).lastPathComponent }
}

/// Result of listing one commit's files.
public struct CommitFileList: Equatable, Sendable {
    public let entries: [CommitTreeEntry]
    /// True when the repo has more files than the requested limit.
    public let truncated: Bool

    public init(entries: [CommitTreeEntry], truncated: Bool = false) {
        self.entries = entries
        self.truncated = truncated
    }

    public var count: Int { entries.count }
}

/// One node of the rendered file tree: either a folder (with children) or a file.
public struct HistoryTreeNode: Identifiable, Equatable, Sendable {
    /// Repo-relative path ("docs/01.md", "docs").
    public let path: String
    /// Last path component.
    public let name: String
    public let isDirectory: Bool
    /// File kind; nil for folders.
    public let kind: CommitTreeEntry.Kind?
    /// Immediate + nested files below this node (0 for files).
    public let fileCount: Int
    public let children: [HistoryTreeNode]

    public var id: String { (isDirectory ? "d:" : "f:") + path }

    public init(path: String, name: String, isDirectory: Bool,
                kind: CommitTreeEntry.Kind?, fileCount: Int,
                children: [HistoryTreeNode]) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind
        self.fileCount = fileCount
        self.children = children
    }
}

/// A visible row of the tree (what the list actually renders).
public struct HistoryTreeRow: Equatable, Sendable {
    public let node: HistoryTreeNode
    public let depth: Int

    public init(node: HistoryTreeNode, depth: Int) {
        self.node = node
        self.depth = depth
    }
}

/// Builds the folder/file hierarchy of a commit's complete file list and
/// flattens it for SwiftUI (visibility follows the expanded-folder set).
///
/// Pure and dependency-free: folders are implied by the file paths, so the
/// same logic works for any number of files and needs no extra git calls.
public enum HistoryTree {
    /// Build a sorted tree: folders first, then files, natural/case-insensitive.
    public static func build(entries: [CommitTreeEntry]) -> [HistoryTreeNode] {
        var paths = Set<String>()
        var byPath: [String: CommitTreeEntry] = [:]
        for entry in entries where !entry.path.isEmpty {
            paths.insert(entry.path)
            byPath[entry.path] = entry
        }
        // Directories implied by every parent path.
        var directories = Set<String>()
        for path in paths {
            var current = path
            while let slash = current.lastIndex(of: "/") {
                current = String(current[current.startIndex..<slash])
                if current.isEmpty { break }
                directories.insert(current)
            }
        }
        return buildLevel(prefix: "", directories: directories, files: byPath)
    }

    private static func buildLevel(prefix: String, directories: Set<String>,
                                   files: [String: CommitTreeEntry]) -> [HistoryTreeNode] {
        let prefixWithSlash = prefix.isEmpty ? "" : prefix + "/"
        var childDirs: Set<String> = []
        var childFiles: [String: CommitTreeEntry] = [:]
        for dir in directories where dir.hasPrefix(prefixWithSlash) && dir != prefix {
            let rest = String(dir.dropFirst(prefixWithSlash.count))
            // Only the immediate child on this level.
            if !rest.contains("/") { childDirs.insert(rest) }
        }
        for (path, entry) in files where path.hasPrefix(prefixWithSlash) {
            let rest = String(path.dropFirst(prefixWithSlash.count))
            if !rest.isEmpty && !rest.contains("/") { childFiles[rest] = entry }
        }

        var dirNodes: [HistoryTreeNode] = childDirs.map { name in
            let path = prefixWithSlash + name
            let children = buildLevel(prefix: path, directories: directories, files: files)
            return HistoryTreeNode(path: path, name: name, isDirectory: true, kind: nil,
                                   fileCount: countFiles(children), children: children)
        }
        dirNodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var fileNodes: [HistoryTreeNode] = childFiles.map { name, entry in
            HistoryTreeNode(path: entry.path, name: name, isDirectory: false,
                            kind: entry.kind, fileCount: 0, children: [])
        }
        fileNodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return dirNodes + fileNodes
    }

    private static func countFiles(_ nodes: [HistoryTreeNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.isDirectory ? $1.fileCount : 1) }
    }

    /// Rows visible for the given expanded folders, depth-first.
    public static func flatten(_ nodes: [HistoryTreeNode],
                               expanded: Set<String>) -> [HistoryTreeRow] {
        var rows: [HistoryTreeRow] = []
        func walk(_ level: [HistoryTreeNode], depth: Int) {
            for node in level {
                rows.append(HistoryTreeRow(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.path) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(nodes, depth: 0)
        return rows
    }

    /// All folder paths in the tree (for "expand all").
    public static func allDirectoryPaths(_ nodes: [HistoryTreeNode]) -> Set<String> {
        var result: Set<String> = []
        func walk(_ level: [HistoryTreeNode]) {
            for node in level where node.isDirectory {
                result.insert(node.path)
                walk(node.children)
            }
        }
        walk(nodes)
        return result
    }

    /// Folder paths that lead to a file path (used to reveal a selection).
    public static func ancestorDirectories(of path: String) -> [String] {
        var result: [String] = []
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[current.startIndex..<slash])
            if current.isEmpty { break }
            result.append(current)
        }
        return result.reversed()
    }
}
