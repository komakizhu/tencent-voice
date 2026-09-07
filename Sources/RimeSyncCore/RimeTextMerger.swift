import Foundation

public enum RimeTextMergeResult: Equatable, Sendable {
    case merged(String)
    case conflict
}

/// Merges two edits against the last version seen by the syncing account.
/// The result is intentionally line-based: it works for YAML, Lua, OpenCC,
/// dictionaries and the other text resources accepted by RimeResourcePolicy.
public enum RimeTextMerger {
    public static func merge(base: String, local: String, shared: String) -> RimeTextMergeResult {
        if local == shared { return .merged(local) }
        if local == base { return .merged(shared) }
        if shared == base { return .merged(local) }

        let baseLines = lines(in: base)
        let localHunks = hunks(from: baseLines, to: lines(in: local))
        let sharedHunks = hunks(from: baseLines, to: lines(in: shared))
        guard let edits = combine(localHunks: localHunks, sharedHunks: sharedHunks) else {
            return .conflict
        }

        var merged: [String] = []
        var cursor = 0
        for edit in edits {
            guard edit.start >= cursor, edit.end <= baseLines.count else { return .conflict }
            merged.append(contentsOf: baseLines[cursor..<edit.start])
            merged.append(contentsOf: edit.replacement)
            cursor = edit.end
        }
        merged.append(contentsOf: baseLines[cursor...])
        return .merged(merged.joined(separator: "\n"))
    }

    private struct Hunk: Equatable {
        let start: Int
        let end: Int
        let replacement: [String]
    }

    private enum DiffOperation {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    private static func lines(in text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func combine(localHunks: [Hunk], sharedHunks: [Hunk]) -> [Hunk]? {
        var edits = localHunks
        for shared in sharedHunks {
            if let sameIndex = edits.firstIndex(where: { $0.start == shared.start && $0.end == shared.end }) {
                let local = edits[sameIndex]
                if local.replacement == shared.replacement { continue }
                if local.start == local.end {
                    edits[sameIndex] = Hunk(
                        start: local.start,
                        end: local.end,
                        replacement: local.replacement == shared.replacement
                            ? local.replacement
                            : local.replacement + shared.replacement
                    )
                    continue
                }
                return nil
            }

            guard !edits.contains(where: { overlaps($0, shared) }) else { return nil }
            edits.append(shared)
        }
        return edits.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
    }

    private static func overlaps(_ lhs: Hunk, _ rhs: Hunk) -> Bool {
        if lhs.start == lhs.end && rhs.start == rhs.end {
            return lhs.start == rhs.start
        }
        if lhs.start == lhs.end {
            return lhs.start >= rhs.start && lhs.start < rhs.end
        }
        if rhs.start == rhs.end {
            return rhs.start >= lhs.start && rhs.start < lhs.end
        }
        return max(lhs.start, rhs.start) < min(lhs.end, rhs.end)
    }

    private static func hunks(from old: [String], to new: [String]) -> [Hunk] {
        let operations = diff(from: old, to: new)
        var result: [Hunk] = []
        var oldIndex = 0
        var operationIndex = 0

        while operationIndex < operations.count {
            if case .equal = operations[operationIndex] {
                oldIndex += 1
                operationIndex += 1
                continue
            }

            let start = oldIndex
            var end = oldIndex
            var replacement: [String] = []
            while operationIndex < operations.count {
                switch operations[operationIndex] {
                case .equal:
                    break
                case let .delete(line):
                    _ = line
                    oldIndex += 1
                    end = oldIndex
                case let .insert(line):
                    replacement.append(line)
                }
                if case .equal = operations[operationIndex] { break }
                operationIndex += 1
            }
            result.append(Hunk(start: start, end: end, replacement: replacement))
        }
        return result
    }

    private static func diff(from old: [String], to new: [String]) -> [DiffOperation] {
        var trace: [[Int: Int]] = []
        var frontier: [Int: Int] = [1: 0]
        var found = false

        for distance in 0...(old.count + new.count) {
            trace.append(frontier)
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let x: Int
                if diagonal == -distance || (diagonal != distance && (frontier[diagonal - 1] ?? -1) < (frontier[diagonal + 1] ?? -1)) {
                    x = frontier[diagonal + 1] ?? 0
                } else {
                    x = (frontier[diagonal - 1] ?? 0) + 1
                }
                var nextX = x
                var nextY = nextX - diagonal
                while nextX < old.count, nextY < new.count, old[nextX] == new[nextY] {
                    nextX += 1
                    nextY += 1
                }
                frontier[diagonal] = nextX
                if nextX >= old.count && nextY >= new.count {
                    found = true
                    break
                }
            }
            if found { break }
        }

        var operations: [DiffOperation] = []
        var x = old.count
        var y = new.count
        for distance in stride(from: trace.count - 1, through: 0, by: -1) {
            let previous = trace[distance]
            let diagonal = x - y
            if distance == 0 {
                while x > 0, y > 0 {
                    operations.append(.equal(old[x - 1]))
                    x -= 1
                    y -= 1
                }
                break
            }

            let previousDiagonal: Int
            if diagonal == -distance || (diagonal != distance && (previous[diagonal - 1] ?? -1) < (previous[diagonal + 1] ?? -1)) {
                previousDiagonal = diagonal + 1
            } else {
                previousDiagonal = diagonal - 1
            }
            let previousX = previous[previousDiagonal] ?? 0
            let previousY = previousX - previousDiagonal
            while x > previousX, y > previousY {
                operations.append(.equal(old[x - 1]))
                x -= 1
                y -= 1
            }
            if x == previousX {
                operations.append(.insert(new[y - 1]))
                y -= 1
            } else {
                operations.append(.delete(old[x - 1]))
                x -= 1
            }
        }
        return operations.reversed()
    }
}
