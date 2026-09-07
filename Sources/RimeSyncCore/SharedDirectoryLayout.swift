import Foundation

public enum SharedDirectoryLayout {
    public static func prepare(
        sharedRoot: URL,
        nodeIDs: [String] = [],
        fileManager: FileManager = .default
    ) throws {
        let directories = [
            sharedRoot,
            sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true),
            sharedRoot.appendingPathComponent("legacy-userdata", isDirectory: true),
            sharedRoot.appendingPathComponent("config", isDirectory: true),
            sharedRoot.appendingPathComponent("config/nodes", isDirectory: true),
            sharedRoot.appendingPathComponent("config/baselines", isDirectory: true),
            sharedRoot.appendingPathComponent("config/conflicts", isDirectory: true),
            sharedRoot.appendingPathComponent("backups", isDirectory: true)
        ] + nodeIDs.map {
            sharedRoot.appendingPathComponent("config/nodes", isDirectory: true).appendingPathComponent($0, isDirectory: true)
        } + nodeIDs.map {
            sharedRoot.appendingPathComponent("config/baselines", isDirectory: true).appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.setAttributes(
                [
                    .posixPermissions: 0o2770,
                    .groupOwnerAccountName: "staff"
                ],
                ofItemAtPath: directory.path
            )
        }
    }

    public static func makeGroupWritable(_ file: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: file.path) else { return }
        try? fileManager.setAttributes(
            [
                .posixPermissions: 0o660,
                .groupOwnerAccountName: "staff"
            ],
            ofItemAtPath: file.path
        )
    }
}
