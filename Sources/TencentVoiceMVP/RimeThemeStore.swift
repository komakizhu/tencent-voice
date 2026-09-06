import Foundation

struct RimeThemeOption: Equatable {
    let id: String
    let displayName: String
    let darkThemeID: String?
}

struct RimeThemeSnapshot: Equatable {
    let themes: [RimeThemeOption]
    let selectedThemeID: String
    let selectedDarkThemeID: String
}

enum RimeThemeStoreError: LocalizedError {
    case configMissing(URL)
    case symbolicLink(URL)
    case invalidConfiguration(String)
    case unknownTheme(String)
    case configurationChanged
    case reloadFailed(Int32, String)
    case reloadTimedOut

    var errorDescription: String? {
        switch self {
        case let .configMissing(url):
            return "找不到 Rime 皮肤配置：\(url.path)"
        case let .symbolicLink(url):
            return "Rime 皮肤配置是符号链接，为避免误替换而停止：\(url.path)"
        case let .invalidConfiguration(message):
            return "Rime 皮肤配置无效：\(message)"
        case let .unknownTheme(id):
            return "找不到 Rime 皮肤：\(id)"
        case .configurationChanged:
            return "Rime 皮肤配置在切换期间发生了变化，请重试。"
        case let .reloadFailed(status, message):
            if message.isEmpty {
                return "鼠须管重新部署失败（退出码 \(status)）"
            }
            return "鼠须管重新部署失败（退出码 \(status)）：\(message)"
        case .reloadTimedOut:
            return "鼠须管重新部署超过 15 秒，已停止等待。"
        }
    }
}

final class RimeThemeStore {
    private let configURL: URL
    private let squirrelURL: URL
    private let fileManager: FileManager
    private let reload: () async throws -> Void

    init(
        configURL: URL,
        squirrelURL: URL = RimeThemeStore.defaultSquirrelURL,
        fileManager: FileManager = .default,
        reload: (() async throws -> Void)? = nil
    ) {
        self.configURL = configURL
        self.squirrelURL = squirrelURL
        self.fileManager = fileManager
        self.reload = reload ?? { [squirrelURL] in
            try await RimeThemeStore.reloadSquirrel(at: squirrelURL)
        }
    }

    convenience init(fileManager: FileManager = .default) {
        let configURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Rime/squirrel.custom.yaml")
        self.init(configURL: configURL, fileManager: fileManager)
    }

    func load() throws -> RimeThemeSnapshot {
        let text = try readConfiguration()
        return try snapshot(from: normalizedLines(from: text))
    }

    @discardableResult
    func select(themeID: String) async throws -> RimeThemeSnapshot {
        let currentText = try readConfiguration()
        let currentLines = normalizedLines(from: currentText)
        let snapshot = try snapshot(from: currentLines)
        guard let theme = snapshot.themes.first(where: { $0.id == themeID }) else {
            throw RimeThemeStoreError.unknownTheme(themeID)
        }

        let darkThemeID = theme.darkThemeID ?? theme.id
        let updatedLines = try replacingStyleValues(
            in: currentLines,
            lightThemeID: theme.id,
            darkThemeID: darkThemeID
        )
        guard try readConfiguration() == currentText else {
            throw RimeThemeStoreError.configurationChanged
        }
        try writeConfiguration(updatedLines.joined(separator: "\n"))
        try await reload()
        return try load()
    }

    private func snapshot(from lines: [String]) throws -> RimeThemeSnapshot {
        let parsedThemes = parseThemes(lines)
        guard !parsedThemes.isEmpty else {
            throw RimeThemeStoreError.invalidConfiguration("没有找到 preset_color_schemes")
        }

        guard let selectedThemeID = styleValue("color_scheme", in: lines),
              let selectedDarkThemeID = styleValue("color_scheme_dark", in: lines)
        else {
            throw RimeThemeStoreError.invalidConfiguration("缺少 style/color_scheme 或 style/color_scheme_dark")
        }

        let themeIDs = Set(parsedThemes.map(\.id))
        let themes = parsedThemes.compactMap { theme -> RimeThemeOption? in
            guard !theme.id.hasSuffix("_dark") else { return nil }
            let darkID = themeIDs.contains("\(theme.id)_dark") ? "\(theme.id)_dark" : nil
            return RimeThemeOption(id: theme.id, displayName: theme.name, darkThemeID: darkID)
        }
        return RimeThemeSnapshot(
            themes: themes,
            selectedThemeID: selectedThemeID,
            selectedDarkThemeID: selectedDarkThemeID
        )
    }

    private func readConfiguration() throws -> String {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw RimeThemeStoreError.configMissing(configURL)
        }
        let values = try configURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw RimeThemeStoreError.symbolicLink(configURL)
        }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    private func writeConfiguration(_ text: String) throws {
        let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
        }
    }

    private func normalizedLines(from text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private struct ParsedTheme {
        let id: String
        let name: String
    }

    private func parseThemes(_ lines: [String]) -> [ParsedTheme] {
        var themes: [ParsedTheme] = []
        var inLegacyThemeMap = false

        for (index, line) in lines.enumerated() {
            if let id = slashThemeID(from: line) {
                themes.append(ParsedTheme(id: id, name: themeName(after: index, header: line, in: lines) ?? id))
                continue
            }

            if line == "  preset_color_schemes:" {
                inLegacyThemeMap = true
                continue
            }
            if inLegacyThemeMap, let id = legacyThemeID(from: line) {
                themes.append(ParsedTheme(id: id, name: themeName(after: index, header: line, in: lines) ?? id))
                continue
            }
            if inLegacyThemeMap, isTwoSpaceKey(line) {
                inLegacyThemeMap = false
            }
        }

        var seen = Set<String>()
        return themes.filter { seen.insert($0.id).inserted }
    }

    private func slashThemeID(from line: String) -> String? {
        let prefix = "  \"preset_color_schemes/"
        guard line.hasPrefix(prefix), line.hasSuffix("\":") else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(line.endIndex, offsetBy: -2)
        let id = String(line[start..<end])
        return id.isEmpty ? nil : id
    }

    private func legacyThemeID(from line: String) -> String? {
        guard line.hasPrefix("    "), line.hasSuffix(":") else { return nil }
        let id = String(line.dropFirst(4).dropLast())
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return id
    }

    private func themeName(after index: Int, header: String, in lines: [String]) -> String? {
        let headerIndent = leadingSpaces(in: header)
        guard index + 1 < lines.count else { return nil }
        for line in lines[(index + 1)...] {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty,
               leadingSpaces(in: line) <= headerIndent {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            let value = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
            return unquote(value)
        }
        return nil
    }

    private func styleValue(_ key: String, in lines: [String]) -> String? {
        var inStyle = false
        for line in lines {
            if line == "  style:" {
                inStyle = true
                continue
            }
            if inStyle, isTwoSpaceKey(line) {
                inStyle = false
            }
            guard inStyle, line.hasPrefix("    \(key):") else { continue }
            let value = String(line.dropFirst(("    \(key):").count)).trimmingCharacters(in: .whitespaces)
            return unquote(value)
        }
        return nil
    }

    private func replacingStyleValues(
        in lines: [String],
        lightThemeID: String,
        darkThemeID: String
    ) throws -> [String] {
        var output: [String] = []
        var inStyle = false
        var replacedLight = false
        var replacedDark = false

        for line in lines {
            if line == "  style:" {
                inStyle = true
                output.append(line)
                continue
            }
            if inStyle, isTwoSpaceKey(line) {
                inStyle = false
            }
            if inStyle, line.hasPrefix("    color_scheme:") {
                output.append("    color_scheme: \(lightThemeID)")
                replacedLight = true
                continue
            }
            if inStyle, line.hasPrefix("    color_scheme_dark:") {
                output.append("    color_scheme_dark: \(darkThemeID)")
                replacedDark = true
                continue
            }
            output.append(line)
        }

        guard replacedLight, replacedDark else {
            throw RimeThemeStoreError.invalidConfiguration("缺少 style/color_scheme 或 style/color_scheme_dark")
        }
        return output
    }

    private func leadingSpaces(in line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private func isTwoSpaceKey(_ line: String) -> Bool {
        line.hasPrefix("  ") && !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func reloadSquirrel(at url: URL) async throws {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            let process = Process()
            let errorPipe = Pipe()
            let completion = ProcessCompletion(process: process, continuation: continuation)
            process.executableURL = url
            process.arguments = ["--reload"]
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 {
                    completion.finish(.success(()))
                } else {
                    completion.finish(.failure(RimeThemeStoreError.reloadFailed(process.terminationStatus, message)))
                }
            }
            do {
                try process.run()
                completion.startTimeout()
            } catch {
                completion.finish(.failure(error))
            }
        }
        try result.get()
    }

    private static var defaultSquirrelURL: URL {
        let fileManager = FileManager.default
        let userURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel")
        if fileManager.isExecutableFile(atPath: userURL.path) {
            return userURL
        }
        return URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel")
    }

    private final class ProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let continuation: CheckedContinuation<Result<Void, Error>, Never>
        private var isFinished = false

        init(
            process: Process,
            continuation: CheckedContinuation<Result<Void, Error>, Never>
        ) {
            self.process = process
            self.continuation = continuation
        }

        func startTimeout() {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let shouldTimeout = !self.isFinished && self.process.isRunning
                if shouldTimeout {
                    self.process.terminate()
                }
                self.lock.unlock()
                if shouldTimeout {
                    self.finish(.failure(RimeThemeStoreError.reloadTimedOut))
                }
            }
        }

        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            lock.unlock()
            continuation.resume(returning: result)
        }
    }
}
