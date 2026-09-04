import CryptoKit
import Foundation
import XCTest
@testable import RimeSyncCore

final class RimeSyncCoreTests: XCTestCase {
    func testPolicyAllowsStableResourcesAndExcludesRuntimeData() {
        XCTAssertTrue(RimeResourcePolicy.isAllowed(relativePath: "rime_ice.schema.yaml"))
        XCTAssertTrue(RimeResourcePolicy.isAllowed(relativePath: "lua/date_translator.lua"))
        XCTAssertTrue(RimeResourcePolicy.isAllowed(relativePath: "opencc/s2t.json"))
        XCTAssertTrue(RimeResourcePolicy.isAllowed(relativePath: "wanxiang-lts-zh-hans.gram"))
        XCTAssertFalse(RimeResourcePolicy.isAllowed(relativePath: "build/rime_ice.table.bin"))
        XCTAssertFalse(RimeResourcePolicy.isAllowed(relativePath: "rime_ice.userdb/00000000"))
        XCTAssertFalse(RimeResourcePolicy.isAllowed(relativePath: "sync/node/rime_ice.userdb.txt"))
        XCTAssertFalse(RimeResourcePolicy.isAllowed(relativePath: "weasel.yaml"))
        XCTAssertFalse(RimeResourcePolicy.isAllowed(relativePath: "installation.yaml"))
    }

    func testInventoryCapturesFilesAndIgnoresExcludedPaths() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha", to: root.appendingPathComponent("rime_ice.schema.yaml"))
        try write("ignored", to: root.appendingPathComponent("build/cache.bin"))
        try write("ignored", to: root.appendingPathComponent("rime_ice.userdb/00000000"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lua"), withIntermediateDirectories: true)
        try write("return {}", to: root.appendingPathComponent("lua/helper.lua"))

        let records = try RimeFileInventory(root: root).scan(owner: "mac")

        XCTAssertEqual(records.map(\.relativePath), ["lua/helper.lua", "rime_ice.schema.yaml"])
        XCTAssertEqual(records.first(where: { $0.relativePath == "rime_ice.schema.yaml" })?.state, .present)
        XCTAssertNotNil(records.first(where: { $0.relativePath == "rime_ice.schema.yaml" })?.sha256)
    }

    func testLastWriterWinsUsesBaselineAndDetectsEqualTimeConflict() throws {
        let baseline = FileRecord.present(path: "one.yaml", modifiedNanoseconds: 100, byteCount: 1, sha256: "a", owner: "mac")
        let local = FileRecord.present(path: "one.yaml", modifiedNanoseconds: 200, byteCount: 1, sha256: "b", owner: "mac")
        let shared = FileRecord.present(path: "one.yaml", modifiedNanoseconds: 150, byteCount: 1, sha256: "c", owner: "mac2")
        XCTAssertEqual(LastWriterWinsResolver.resolve(local: local, shared: shared, baseline: baseline), .local)

        let sameTimeLocal = FileRecord.present(path: "one.yaml", modifiedNanoseconds: 300, byteCount: 1, sha256: "local", owner: "mac")
        let sameTimeShared = FileRecord.present(path: "one.yaml", modifiedNanoseconds: 300, byteCount: 1, sha256: "shared", owner: "mac2")
        XCTAssertEqual(LastWriterWinsResolver.resolve(local: sameTimeLocal, shared: sameTimeShared, baseline: baseline), .conflict)
    }

    func testManifestRoundTripsAndTracksTombstones() throws {
        let active = FileRecord.present(path: "active.yaml", modifiedNanoseconds: 123, byteCount: 4, sha256: "hash", owner: "mac")
        let removed = FileRecord.tombstone(path: "removed.yaml", modifiedNanoseconds: 124, owner: "mac2")
        let manifest = RimeManifest(records: [active.relativePath: active, removed.relativePath: removed])
        let data = try JSONEncoder.rimeEncoder.encode(manifest)
        let decoded = try JSONDecoder.rimeDecoder.decode(RimeManifest.self, from: data)

        XCTAssertEqual(decoded.records["active.yaml"]?.sha256, "hash")
        XCTAssertEqual(decoded.records["removed.yaml"]?.state, .tombstone)
    }

    func testSyncPublishesLocalFileAndCreatesBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try write("local", to: local.appendingPathComponent("rime_ice.custom.yaml"))
        let maintenance = FakeMaintenance()
        let engine = DefaultRimeSyncEngine(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main"),
            maintenance: maintenance
        )

        let report = try engine.sync()

        XCTAssertEqual(report.changedFiles, ["rime_ice.custom.yaml"])
        XCTAssertTrue(report.userDictionarySyncSucceeded)
        XCTAssertEqual(maintenance.calls, ["sync", "reload"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("config/nodes/mac2/rime_ice.custom.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("backups/\(report.backupID)/mac2/Rime/rime_ice.custom.yaml").path))
        let manifestPermissions = try FileManager.default.attributesOfItem(atPath: shared.appendingPathComponent("config/manifest.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((manifestPermissions?.intValue ?? 0) & 0o660, 0o660)
    }

    func testSyncPullsNewerSharedFileWithoutOverwritingUserdb() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let remoteNode = shared.appendingPathComponent("config/nodes/mac", isDirectory: true)
        try write("old", to: local.appendingPathComponent("rime_ice.custom.yaml"))
        try write("new", to: remoteNode.appendingPathComponent("rime_ice.custom.yaml"))
        let old = FileRecord.present(path: "rime_ice.custom.yaml", modifiedNanoseconds: 100, byteCount: 3, sha256: digest("old"), owner: "mac")
        let new = FileRecord.present(path: "rime_ice.custom.yaml", modifiedNanoseconds: 200, byteCount: 3, sha256: digest("new"), owner: "mac")
        let manifest = RimeManifest(
            records: [new.relativePath: new],
            nodes: ["mac2": [old.relativePath: old], "mac": [new.relativePath: new]]
        )
        try manifest.saving(to: shared.appendingPathComponent("config/manifest.json"))
        try write("private-db", to: local.appendingPathComponent("rime_ice.userdb/00000000"))

        let maintenance = FakeMaintenance()
        let engine = DefaultRimeSyncEngine(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main"),
            maintenance: maintenance
        )
        let report = try engine.sync(dryRun: true)
        XCTAssertEqual(report.changedFiles, ["rime_ice.custom.yaml"])
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("rime_ice.custom.yaml")), "old")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("rime_ice.userdb/00000000")), "private-db")
        XCTAssertTrue(maintenance.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("backups").path))

        let actual = try engine.sync()
        XCTAssertEqual(actual.changedFiles, ["rime_ice.custom.yaml"])
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("rime_ice.custom.yaml")), "new")
    }

    func testEqualTimestampConflictIsPausedAndPreservesLocalFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let remoteNode = shared.appendingPathComponent("config/nodes/mac", isDirectory: true)
        try write("local", to: local.appendingPathComponent("rime_ice.custom.yaml"))
        try write("shared", to: remoteNode.appendingPathComponent("rime_ice.custom.yaml"))
        let baseline = FileRecord.present(path: "rime_ice.custom.yaml", modifiedNanoseconds: 100, byteCount: 4, sha256: digest("base"), owner: "mac2")
        let localRecord = try XCTUnwrap(RimeFileInventory(root: local).scan(owner: "mac2").first)
        let sharedRecord = FileRecord.present(
            path: "rime_ice.custom.yaml",
            modifiedNanoseconds: localRecord.modifiedNanoseconds,
            byteCount: 6,
            sha256: digest("shared"),
            owner: "mac"
        )
        try RimeManifest(
            records: [sharedRecord.relativePath: sharedRecord],
            nodes: ["mac2": [baseline.relativePath: baseline], "mac": [sharedRecord.relativePath: sharedRecord]]
        ).saving(to: shared.appendingPathComponent("config/manifest.json"))

        let report = try DefaultRimeSyncEngine(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main"),
            maintenance: FakeMaintenance()
        ).sync()

        XCTAssertEqual(report.conflicts, ["rime_ice.custom.yaml"])
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("rime_ice.custom.yaml")), "local")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("config/conflicts/\(report.backupID)/rime_ice.custom.yaml.mac2.local").path))
        let saved = try RimeManifest.loading(from: shared.appendingPathComponent("config/manifest.json"))
        XCTAssertTrue(saved.pausedPaths.contains("rime_ice.custom.yaml"))
    }

    func testBackupManagerKeepsOnlyThreeBackups() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try write("config", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let manager = RimeBackupManager()
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main")
        for _ in 0..<5 { _ = try manager.createBackup(configuration: configuration) }
        let backups = try FileManager.default.contentsOfDirectory(at: configuration.backupRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(backups.count, 3)
    }

    func testDeletingLocalFilePublishesTombstoneAndRemovesSharedCopy() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let localNode = shared.appendingPathComponent("config/nodes/mac2", isDirectory: true)
        try write("old", to: local.appendingPathComponent("rime_ice.custom.yaml"))
        try write("old", to: localNode.appendingPathComponent("rime_ice.custom.yaml"))
        let record = FileRecord.present(path: "rime_ice.custom.yaml", modifiedNanoseconds: 100, byteCount: 3, sha256: digest("old"), owner: "mac2")
        try RimeManifest(records: [record.relativePath: record], nodes: ["mac2": [record.relativePath: record]])
            .saving(to: shared.appendingPathComponent("config/manifest.json"))
        try FileManager.default.removeItem(at: local.appendingPathComponent("rime_ice.custom.yaml"))

        let report = try DefaultRimeSyncEngine(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main"),
            maintenance: FakeMaintenance()
        ).sync()

        XCTAssertEqual(report.deletedFiles, ["rime_ice.custom.yaml"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: localNode.appendingPathComponent("rime_ice.custom.yaml").path))
        XCTAssertEqual(try RimeManifest.loading(from: shared.appendingPathComponent("config/manifest.json")).records["rime_ice.custom.yaml"]?.state, .tombstone)
    }

    func testTwoAccountsExchangeAConfigChangeThroughSharedManifest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let macLocal = root.appendingPathComponent("mac/Rime", isDirectory: true)
        let mac2Local = root.appendingPathComponent("mac2/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try write("first", to: macLocal.appendingPathComponent("rime_ice.custom.yaml"))
        try write("first", to: mac2Local.appendingPathComponent("rime_ice.custom.yaml"))
        let macEngine = DefaultRimeSyncEngine(
            configuration: SyncConfiguration(localRimeDirectory: macLocal, sharedRoot: shared, installationID: "mac-id", nodeID: "mac"),
            maintenance: FakeMaintenance()
        )
        let mac2Engine = DefaultRimeSyncEngine(
            configuration: SyncConfiguration(localRimeDirectory: mac2Local, sharedRoot: shared, installationID: "mac2-main", nodeID: "mac2"),
            maintenance: FakeMaintenance()
        )
        _ = try macEngine.sync()
        _ = try mac2Engine.sync()
        try write("second", to: mac2Local.appendingPathComponent("rime_ice.custom.yaml"))
        _ = try mac2Engine.sync()
        _ = try macEngine.sync()

        XCTAssertEqual(try String(contentsOf: macLocal.appendingPathComponent("rime_ice.custom.yaml")), "second")
        XCTAssertEqual(try String(contentsOf: mac2Local.appendingPathComponent("rime_ice.custom.yaml")), "second")
    }

    func testRestoreReplacesCurrentRimeWithSelectedBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try write("before", to: local.appendingPathComponent("rime_ice.custom.yaml"))
        let manager = RimeBackupManager()
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main")
        let backupID = try manager.createBackup(configuration: configuration)
        try write("after", to: local.appendingPathComponent("rime_ice.custom.yaml"))

        try manager.restore(backupID: backupID, configuration: configuration)

        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("rime_ice.custom.yaml")), "before")
    }

    func testDirectoryLockReleasesAfterFailureAndRejectsNestedLock() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent(".lock", isDirectory: true)
        let lock = DirectoryLock(lockURL: lockURL)
        XCTAssertThrowsError(try lock.withLock {
            XCTAssertThrowsError(try lock.withLock {})
            throw RimeSyncError.unsupportedOperation("test")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertNoThrow(try lock.withLock {})
    }

    func testInstallationFilePreservesExistingConfigAndUpdatesIdentityAndSyncDir() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("installation.yaml")
        try write("distribution_name: Squirrel\ninstallation_id: 'old'\n", to: file)
        try RimeInstallationFile.updating(
            existingURL: file,
            installationID: "mac2-main",
            syncDirectory: URL(fileURLWithPath: "/Users/Shared/RimeSync/rime-userdata")
        )
        let parsed = try XCTUnwrap(RimeInstallationFile.loading(from: file))
        XCTAssertEqual(parsed.installationID, "mac2-main")
        XCTAssertEqual(parsed.syncDirectory, "/Users/Shared/RimeSync/rime-userdata")
        XCTAssertTrue(try String(contentsOf: file).contains("distribution_name: Squirrel"))
    }

    func testBootstrapCapturesPortableHelperAndSeparatesLegacyUserData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace/rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try write("TARGET_DIR=\"/Users/mac/Library/Rime\"\n", to: source.appendingPathComponent("Rime配置助手.command"))
        try write("schema", to: source.appendingPathComponent("rime_ice.schema.yaml"))
        try write("runtime", to: source.appendingPathComponent("build/cache.bin"))
        try write("raw", to: source.appendingPathComponent("rime_ice.userdb/00000000"))
        try write("old", to: source.appendingPathComponent("sync/id/rime_ice.userdb.txt"))
        try write("legacy", to: source.appendingPathComponent("sync/id/luna_pinyin.userdb.txt"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("luna_pinyin.userdb"), withIntermediateDirectories: true)
        try write("raw", to: source.appendingPathComponent("luna_pinyin.userdb/00000000"))

        let bootstrapper = RimeBootstrapper()
        _ = try bootstrapper.captureStableResources(from: source, to: workspace)
        try bootstrapper.initializeShared(from: source, sharedRoot: shared, sourceInstallationID: "id")

        let helper = try String(contentsOf: workspace.appendingPathComponent("Rime配置助手.command"))
        XCTAssertTrue(helper.contains("$HOME/Library/Rime"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("build/cache.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("rime-userdata/id/rime_ice.userdb.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("legacy-userdata/snapshots/id/luna_pinyin.userdb.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("legacy-userdata/raw/luna_pinyin.userdb/00000000").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("rime-userdata/id/luna_pinyin.userdb.txt").path))
    }

    func testBootstrapRejectsUserdbOlderSnapshot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try write("raw", to: source.appendingPathComponent("rime_ice.userdb/00000000"))
        try write("snapshot", to: source.appendingPathComponent("sync/id/rime_ice.userdb.txt"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: source.appendingPathComponent("rime_ice.userdb").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: source.appendingPathComponent("sync/id/rime_ice.userdb.txt").path
        )

        XCTAssertThrowsError(try RimeBootstrapper().initializeShared(from: source, sharedRoot: shared, sourceInstallationID: "id")) { error in
            XCTAssertTrue(error.localizedDescription.contains("比同步快照更新"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("config/manifest.json").path))
    }

    func testSquirrelMaintenanceRejectsFailedCommand() throws {
        let runner = FakeCommandRunner(result: CommandResult(status: 1, output: "failed"))
        let maintenance = SquirrelMaintenance(runner: runner)
        XCTAssertThrowsError(try maintenance.syncUserData()) { error in
            XCTAssertTrue(error.localizedDescription.contains("返回 1"))
        }
        XCTAssertEqual(runner.arguments, [["--sync"]])
    }

    func testVerifierDetectsSharedNodeHashDrift() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2-main")
        let syncPath = shared.appendingPathComponent("rime-userdata").path
        try write("installation_id: 'mac2-main'\nsync_dir: '\(syncPath)'\n", to: local.appendingPathComponent("installation.yaml"))
        try write("stable", to: configuration.nodeDirectory.appendingPathComponent("rime_ice.schema.yaml"))
        let record = try XCTUnwrap(RimeFileInventory(root: configuration.nodeDirectory).scan(owner: "mac2").first)
        try RimeManifest(records: [record.relativePath: record], nodes: ["mac2": [record.relativePath: record]])
            .saving(to: configuration.manifestURL)

        XCTAssertTrue(RimeVerifier().verify(configuration: configuration).isValid)
        try write("changed", to: configuration.nodeDirectory.appendingPathComponent("rime_ice.schema.yaml"))
        let result = RimeVerifier().verify(configuration: configuration)
        XCTAssertTrue(result.issues.contains(where: { $0.contains("哈希不一致") }))
    }

    func testSharedDirectoryLayoutCreatesGroupWritableDirectories() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("shared", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try SharedDirectoryLayout.prepare(sharedRoot: root, nodeIDs: ["mac", "mac2"])

        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o770, 0o770)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("config/nodes/mac2").path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeSyncCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }

    private func digest(_ string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeMaintenance: NativeRimeMaintaining {
    var calls: [String] = []

    func syncUserData() throws { calls.append("sync") }
    func reload() throws { calls.append("reload") }
}

private final class FakeCommandRunner: CommandRunning {
    let result: CommandResult
    var arguments: [[String]] = []

    init(result: CommandResult) {
        self.result = result
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        self.arguments.append(arguments)
        return result
    }
}
