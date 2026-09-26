import Foundation
import XCTest
@testable import RimeSyncCore

final class RimePortableArchiveTests: XCTestCase {
    func testExportPreviewListsPortableFilesAndEstimatedSize() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        try write("byy\t备用词\t1\n", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("identity", to: source.appendingPathComponent("installation.yaml"))

        let preview = try RimePortableArchiveService().previewExport(from: source)

        XCTAssertEqual(preview.files.map(\.relativePath), ["custom_phrase.txt", "squirrel.custom.yaml"])
        XCTAssertEqual(preview.totalBytes, Int64("byy\t备用词\t1\n".utf8.count + "skin".utf8.count))
    }

    func testExportRejectsChangesMadeAfterPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let phraseURL = source.appendingPathComponent("custom_phrase.txt")
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        try write("old", to: phraseURL)
        let preview = try RimePortableArchiveService().previewExport(from: source)
        try write("new", to: phraseURL)

        XCTAssertThrowsError(try RimePortableArchiveService().export(from: source, to: archive, expectedPreview: preview)) { error in
            XCTAssertEqual(error as? RimePortableArchiveError, .sourceChanged("配置目录已在导出预览后变化"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testExportValidationFailurePreservesExistingArchive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("existing.rimevoiceconfig")
        let existingArchive = Data("previous valid archive".utf8)
        try write("byy\t备用短语\t1\n", to: source.appendingPathComponent("custom_phrase.txt"))
        try existingArchive.write(to: archive)

        let service = RimePortableArchiveService(fileManager: RejectTemporaryArchiveValidationFileManager())

        XCTAssertThrowsError(try service.export(from: source, to: archive))
        XCTAssertEqual(try Data(contentsOf: archive), existingArchive)
    }

    func testExportIncludesPortableConfigurationAndExcludesRuntimeIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        try write("byy\t备用词\t1\n", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("managed", to: source.appendingPathComponent("rime_managed.dict.yaml"))
        try write("model", to: source.appendingPathComponent("wanxiang-lts-zh-hans.gram"))
        try write("helper", to: source.appendingPathComponent("Rime配置助手.command"))
        try write("secret", to: source.appendingPathComponent("credentials.yaml"))
        try write("secret", to: source.appendingPathComponent("lua/client_secret.lua"))
        try write("secret", to: source.appendingPathComponent("opencc/api_key.json"))
        try write("identity", to: source.appendingPathComponent("installation.yaml"))
        try write("runtime", to: source.appendingPathComponent("build/generated.bin"))
        try write("live", to: source.appendingPathComponent("rime_ice.userdb/00000000"))
        try write("snapshot", to: source.appendingPathComponent("sync/mac/rime_ice.userdb.txt"))

        let result = try RimePortableArchiveService().export(from: source, to: archive)

        XCTAssertEqual(Set(result.files.map(\.relativePath)), [
            "Rime配置助手.command",
            "custom_phrase.txt",
            "rime_managed.dict.yaml",
            "squirrel.custom.yaml",
            "wanxiang-lts-zh-hans.gram"
        ])
        XCTAssertEqual(result.totalBytes, Int64("byy\t备用词\t1\n".utf8.count + "skin".utf8.count + "managed".utf8.count + "model".utf8.count + "helper".utf8.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testImportPreviewReplacesOnlyChangedFilesAndKeepsTargetOnlyFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("new skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("same", to: source.appendingPathComponent("same.yaml"))
        try write("old phrase", to: target.appendingPathComponent("custom_phrase.txt"))
        try write("same", to: target.appendingPathComponent("same.yaml"))
        try write("target-only", to: target.appendingPathComponent("target-only.yaml"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let service = RimePortableArchiveService()

        let preview = try service.previewImport(from: archive, to: target)

        XCTAssertEqual(preview.additions.map(\.relativePath), ["squirrel.custom.yaml"])
        XCTAssertEqual(preview.replacements.map(\.relativePath), ["custom_phrase.txt"])
        XCTAssertEqual(preview.unchanged.map(\.relativePath), ["same.yaml"])

        let report = try service.importArchive(from: archive, to: target, backupRoot: backupRoot, expectedArchiveSHA256: preview.archiveSHA256)

        XCTAssertEqual(report.addedFiles, ["squirrel.custom.yaml"])
        XCTAssertEqual(report.replacedFiles, ["custom_phrase.txt"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "new phrase")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("squirrel.custom.yaml"), encoding: .utf8), "new skin")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("target-only.yaml"), encoding: .utf8), "target-only")
        XCTAssertFalse(report.backupID.isEmpty)
    }

    func testCrossAccountArchiveRestoresPhraseSkinMainDictionaryAndManagedEntries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mac2 = root.appendingPathComponent("mac2/Rime", isDirectory: true)
        let mac1 = root.appendingPathComponent("mac1/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("mac2.rimevoiceconfig")
        let localStateRoot = root.appendingPathComponent("mac1/Application Support/Rime Voice/Review", isDirectory: true)
        let backupRoot = localStateRoot.appendingPathComponent("backups", isDirectory: true)
        let oldLocalEntry = RimeManagedEntryState(text: "旧本机词条", code: "jiu", sourceFrequencies: ["local": 1])
        try RimeReviewStore(url: localStateRoot.appendingPathComponent("config/rime-review-state.json"))
            .save(RimeReviewState(initialized: true, entries: [oldLocalEntry.identity: oldLocalEntry]))
        try write("备用短语\tbyy\t1\n", to: mac2.appendingPathComponent("custom_phrase.txt"))
        try write("skin: mac2\n", to: mac2.appendingPathComponent("squirrel.custom.yaml"))
        try write("import_tables:\n  - rime_managed\n", to: mac2.appendingPathComponent("rime_ice.dict.yaml"))
        try write("---\nname: rime_managed\n...\n永久短语\tbyy\t1\n", to: mac2.appendingPathComponent("rime_managed.dict.yaml"))
        try write("old phrase\n", to: mac1.appendingPathComponent("custom_phrase.txt"))
        try write("skin: mac1\n", to: mac1.appendingPathComponent("squirrel.custom.yaml"))
        try write("target-only\n", to: mac1.appendingPathComponent("target-only.yaml"))

        let service = RimePortableArchiveService()
        _ = try service.export(from: mac2, to: archive)
        let preview = try service.previewImport(from: archive, to: mac1)
        let maintenance = PortableArchiveMaintenanceSpy()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: mac1, sharedRoot: localStateRoot, installationID: "mac1"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: PortableArchiveSyncSpy(),
            storageMode: .local
        )
        let report = try service.importAndDeploy(
            from: archive,
            to: mac1,
            backupRoot: backupRoot,
            expectedPreview: preview,
            protectedPaths: ["rime_ice.dict.yaml", RimeManagedDictionary.fileName],
            backupDependentState: { try coordinator.backupLocalReviewStateForConfigurationImport(at: $0) },
            prepareAfterImport: { registerPreparedFile in
                try coordinator.reconcileManagedDictionaryAfterImport(registerPreparedFile: registerPreparedFile)
            },
            deploy: { try maintenance.reload() },
            restoreAfterRollback: { backupDirectory in
                try coordinator.restoreLocalReviewStateFromConfigurationImport(at: backupDirectory)
                try maintenance.reload()
            }
        )

        XCTAssertTrue(try String(contentsOf: mac1.appendingPathComponent("custom_phrase.txt"), encoding: .utf8).contains("byy"))
        XCTAssertEqual(try String(contentsOf: mac1.appendingPathComponent("squirrel.custom.yaml"), encoding: .utf8), "skin: mac2\n")
        XCTAssertTrue(try String(contentsOf: mac1.appendingPathComponent("rime_ice.dict.yaml"), encoding: .utf8).contains("rime_managed"))
        XCTAssertTrue(try String(contentsOf: mac1.appendingPathComponent("rime_managed.dict.yaml"), encoding: .utf8).contains("永久短语\tbyy\t1"))
        XCTAssertEqual(
            try String(contentsOf: mac1.appendingPathComponent("rime_managed.dict.yaml"), encoding: .utf8),
            try String(contentsOf: mac2.appendingPathComponent("rime_managed.dict.yaml"), encoding: .utf8)
        )
        XCTAssertEqual(try String(contentsOf: mac1.appendingPathComponent("target-only.yaml"), encoding: .utf8), "target-only\n")
        let entryID = RimeUserDictionaryEntry.identity(for: "永久短语", code: "byy")
        XCTAssertEqual(try coordinator.reviewState().entries[entryID]?.text, "永久短语")
        XCTAssertNil(try coordinator.reviewState().entries[oldLocalEntry.identity])
        XCTAssertFalse(report.backupID.isEmpty)
    }

    func testRepairingMainDictionaryWithoutChangingManagedDictionaryPreservesReviewHistory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rime = root.appendingPathComponent("target/Rime", isDirectory: true)
        let reviewRoot = root.appendingPathComponent("target/Application Support/Rime Voice/Review", isDirectory: true)
        let mainDictionary = rime.appendingPathComponent("rime_ice.dict.yaml")
        let managedDictionary = rime.appendingPathComponent(RimeManagedDictionary.fileName)
        try write("import_tables:\n  - base_table\n", to: mainDictionary)
        try write("---\nname: rime_managed\n...\n保留词条\tbyy\t1\n", to: managedDictionary)
        let entry = RimeManagedEntryState(text: "保留词条", code: "byy", sourceFrequencies: ["local": 3])
        let originalState = RimeReviewState(
            initialized: true,
            entries: [entry.identity: entry],
            lastAppliedSnapshotDigests: ["installation": "kept-digest"],
            permanentIgnoredIDs: ["kept-ignore"]
        )
        let reviewStore = RimeReviewStore(url: reviewRoot.appendingPathComponent("config/rime-review-state.json"), groupWritable: false)
        try reviewStore.save(originalState)
        let maintenance = PortableArchiveMaintenanceSpy()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: rime, sharedRoot: reviewRoot, installationID: "mac1"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: PortableArchiveSyncSpy(),
            storageMode: .local
        )
        var preparedPaths: [String] = []

        try coordinator.reconcileManagedDictionaryAfterImport(rebuildReviewState: false) { path, _ in
            preparedPaths.append(path)
        }

        XCTAssertEqual(preparedPaths, ["rime_ice.dict.yaml"])
        XCTAssertTrue(try String(contentsOf: mainDictionary, encoding: .utf8).contains("  - rime_managed"))
        XCTAssertEqual(try reviewStore.load(), originalState)
    }

    func testDeploymentFailureRollsBackAndRestoresPreviousConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("old skin", to: target.appendingPathComponent("squirrel.custom.yaml"))
        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let preview = try service.previewImport(from: archive, to: target)
        var prepareCalls = 0
        var deployCalls = 0
        var restoreCalls = 0

        XCTAssertThrowsError(try service.importAndDeploy(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            expectedPreview: preview,
            prepareAfterImport: { _ in prepareCalls += 1 },
            deploy: {
                deployCalls += 1
                throw RimeSyncError.unsupportedOperation("模拟 Squirrel 重新部署失败")
            },
            restoreAfterRollback: { _ in restoreCalls += 1 }
        )) { error in
            guard let archiveError = error as? RimePortableArchiveError,
                  case .deploymentFailed = archiveError else {
                return XCTFail("Expected rollback-complete deployment error, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("squirrel.custom.yaml"), encoding: .utf8), "old skin")
        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(deployCalls, 1)
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testPrepareFailureRollsBackJournaledDictionaryTransformation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let mainDictionary = target.appendingPathComponent("rime_ice.dict.yaml")
        try write("import_tables:\n  - incoming\n", to: source.appendingPathComponent("rime_ice.dict.yaml"))
        try write("---\nname: rime_managed\n...\n新词\txin\t1\n", to: source.appendingPathComponent(RimeManagedDictionary.fileName))
        try write("import_tables:\n  - original\n", to: mainDictionary)
        try write("---\nname: rime_managed\n...\n旧词\tjiu\t1\n", to: target.appendingPathComponent(RimeManagedDictionary.fileName))

        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let preview = try service.previewImport(from: archive, to: target)
        XCTAssertThrowsError(try service.importAndDeploy(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            expectedPreview: preview,
            protectedPaths: ["rime_ice.dict.yaml"],
            prepareAfterImport: { registerPreparedFile in
                let preparedData = Data("import_tables:\n  - incoming\n  - rime_managed\n".utf8)
                try registerPreparedFile("rime_ice.dict.yaml", preparedData)
                try preparedData.write(to: mainDictionary)
                throw RimeSyncError.unsupportedOperation("模拟准备阶段中断")
            },
            deploy: { XCTFail("准备失败时不应部署") },
            restoreAfterRollback: { _ in }
        )) { error in
            guard let archiveError = error as? RimePortableArchiveError,
                  case .deploymentFailed = archiveError else {
                return XCTFail("Expected completed rollback after prepare failure, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: mainDictionary, encoding: .utf8), "import_tables:\n  - original\n")
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent(RimeManagedDictionary.fileName), encoding: .utf8),
            "---\nname: rime_managed\n...\n旧词\tjiu\t1\n"
        )
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testFailedDeploymentRestoresAbsentManagedReviewStateWithoutResurrectingImportedEntries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mac2/Rime", isDirectory: true)
        let target = root.appendingPathComponent("mac1/Rime", isDirectory: true)
        let localStateRoot = root.appendingPathComponent("mac1/Application Support/Rime Voice/Review", isDirectory: true)
        let backupRoot = localStateRoot.appendingPathComponent("backups", isDirectory: true)
        let archive = root.appendingPathComponent("mac2.rimevoiceconfig")
        let mainDictionary = target.appendingPathComponent("rime_ice.dict.yaml")
        try write("import_tables:\n  - base_only\n", to: source.appendingPathComponent("rime_ice.dict.yaml"))
        try write("---\nname: rime_managed\n...\n导入词条\tbyy\t1\n", to: source.appendingPathComponent("rime_managed.dict.yaml"))
        try write("import_tables:\n  - original_table\n", to: mainDictionary)
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let service = RimePortableArchiveService()
        let preview = try service.previewImport(from: archive, to: target)
        let maintenance = PortableArchiveMaintenanceSpy()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: target, sharedRoot: localStateRoot, installationID: "mac1"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: PortableArchiveSyncSpy(),
            storageMode: .local
        )

        XCTAssertThrowsError(try service.importAndDeploy(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            expectedPreview: preview,
            protectedPaths: ["rime_ice.dict.yaml", RimeManagedDictionary.fileName],
            backupDependentState: { try coordinator.backupLocalReviewStateForConfigurationImport(at: $0) },
            prepareAfterImport: { registerPreparedFile in
                try coordinator.reconcileManagedDictionaryAfterImport(registerPreparedFile: registerPreparedFile)
            },
            deploy: { throw RimeSyncError.unsupportedOperation("模拟部署失败") },
            restoreAfterRollback: { backupDirectory in
                try coordinator.restoreLocalReviewStateFromConfigurationImport(at: backupDirectory)
                try maintenance.reload()
            }
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("rime_managed.dict.yaml").path))
        XCTAssertEqual(try String(contentsOf: mainDictionary, encoding: .utf8), "import_tables:\n  - original_table\n")
        XCTAssertTrue(try coordinator.reviewState().entries.isEmpty)
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testRollbackRemainsRecoverableWhenRestoringRimeFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let targetURL = target.appendingPathComponent("squirrel.custom.yaml")
        try write("new skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("old skin", to: targetURL)
        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let preview = try service.previewImport(from: archive, to: target)

        XCTAssertThrowsError(try service.importAndDeploy(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            expectedPreview: preview,
            prepareAfterImport: { _ in },
            deploy: { throw RimeSyncError.unsupportedOperation("模拟重新部署失败") },
            restoreAfterRollback: { _ in throw RimeSyncError.unsupportedOperation("模拟回滚后重新加载失败") }
        ))

        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "old skin")
        let pending = try service.pendingRecoveries(in: backupRoot)
        XCTAssertEqual(pending.count, 1)
        try service.restoreImportFiles(backupID: pending[0].id, in: backupRoot, targetDirectory: target)
        try service.completeRollback(backupID: pending[0].id, in: backupRoot)
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testWriteFailureReloadsRolledBackConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("new skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("old phrase", to: target.appendingPathComponent("custom_phrase.txt"))
        try write("old skin", to: target.appendingPathComponent("squirrel.custom.yaml"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let service = RimePortableArchiveService(fileManager: FailingStagedCopyFileManager(failureNumber: 2))
        let preview = try service.previewImport(from: archive, to: target)
        var reloadCalls = 0

        XCTAssertThrowsError(try service.importAndDeploy(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            expectedPreview: preview,
            prepareAfterImport: { _ in },
            deploy: { XCTFail("写入失败时不应部署新配置") },
            restoreAfterRollback: { _ in reloadCalls += 1 }
        ))

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "old phrase")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("squirrel.custom.yaml"), encoding: .utf8), "old skin")
        XCTAssertEqual(reloadCalls, 1)
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testRepeatedImportDoesNotCreateBackupOrRewriteFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("stable", to: source.appendingPathComponent("custom_phrase.txt"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let service = RimePortableArchiveService()

        let first = try service.importArchive(from: archive, to: target, backupRoot: backupRoot)
        let destination = target.appendingPathComponent("custom_phrase.txt")
        let originalDate = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        let second = try service.importArchive(from: archive, to: target, backupRoot: backupRoot)
        let repeatedDate = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date

        XCTAssertFalse(first.backupID.isEmpty)
        XCTAssertTrue(second.backupID.isEmpty)
        XCTAssertTrue(second.addedFiles.isEmpty)
        XCTAssertTrue(second.replacedFiles.isEmpty)
        XCTAssertEqual(originalDate, repeatedDate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).count, 1)
    }

    func testImportRejectsTargetChangesAfterPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("archive phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("old phrase", to: target.appendingPathComponent("custom_phrase.txt"))
        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let preview = try service.previewImport(from: archive, to: target)
        try write("new local edit", to: target.appendingPathComponent("custom_phrase.txt"))

        XCTAssertThrowsError(try service.importArchive(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            expectedPreview: preview
        )) { error in
            XCTAssertEqual(error as? RimePortableArchiveError, .targetChanged)
        }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "new local edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
    }

    func testRollbackRefusesToOverwriteProtectedConfigurationChangedAfterImport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new managed", to: source.appendingPathComponent("rime_managed.dict.yaml"))
        try write("old managed", to: target.appendingPathComponent("rime_managed.dict.yaml"))
        try write("old main dictionary", to: target.appendingPathComponent("rime_ice.dict.yaml"))
        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)

        let report = try service.importArchive(
            from: archive,
            to: target,
            backupRoot: backupRoot,
            protectedPaths: ["rime_ice.dict.yaml"]
        )
        try write("deployed import table", to: target.appendingPathComponent("rime_ice.dict.yaml"))

        XCTAssertThrowsError(try service.rollbackImport(backupID: report.backupID, in: backupRoot, targetDirectory: target)) { error in
            XCTAssertEqual(error as? RimePortableArchiveError, .recoveryConflict("rime_ice.dict.yaml"))
        }

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("rime_managed.dict.yaml"), encoding: .utf8), "new managed")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("rime_ice.dict.yaml"), encoding: .utf8), "deployed import table")
        XCTAssertEqual(try service.pendingRecoveries(in: backupRoot).map(\.id), [report.backupID])
    }

    func testCorruptPayloadIsRejectedBeforeTargetChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("archive payload", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("old target", to: target.appendingPathComponent("custom_phrase.txt"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: archive)

        XCTAssertThrowsError(try RimePortableArchiveService().importArchive(from: archive, to: target, backupRoot: backupRoot))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "old target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
    }

    func testExportRejectsAllowedSymlinkInsteadOfArchivingExternalContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let external = root.appendingPathComponent("external.txt")
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        try write("secret", to: external)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("custom_phrase.txt"), withDestinationURL: external)

        XCTAssertThrowsError(try RimePortableArchiveService().export(from: source, to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testUnknownFormatVersionIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        try write("phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        var bytes = try Data(contentsOf: archive)
        bytes[11] = 2
        try bytes.write(to: archive)

        XCTAssertThrowsError(try RimePortableArchiveService().inspect(archive)) { error in
            XCTAssertEqual(error as? RimePortableArchiveError, .unsupportedVersion(2))
        }
    }

    func testArchiveRejectsTraversalPathInManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        try write("phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        var bytes = try Data(contentsOf: archive)
        let originalPath = Data("custom_phrase.txt".utf8)
        let maliciousPath = Data("../12345678901234".utf8)
        XCTAssertEqual(originalPath.count, maliciousPath.count)
        let range = try XCTUnwrap(bytes.range(of: originalPath))
        bytes.replaceSubrange(range, with: maliciousPath)
        try bytes.write(to: archive)

        XCTAssertThrowsError(try RimePortableArchiveService().inspect(archive)) { error in
            guard case let .invalidPath(path) = error as? RimePortableArchiveError else {
                return XCTFail("Expected invalid path error, got \(error)")
            }
            XCTAssertEqual(path, "../12345678901234")
        }
    }

    func testArchiveRejectsCaseAndUnicodeNormalizedPathAliases() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("aliases.rimevoiceconfig")
        let aliases = [
            ["Theme.yaml", "theme.yaml"],
            ["café.yaml", "cafe\u{301}.yaml"]
        ]

        for paths in aliases {
            try writeEmptyPayloadArchive(paths: paths, to: archive)
            XCTAssertThrowsError(try RimePortableArchiveService().inspect(archive)) { error in
                guard case let .invalidArchive(message) = error as? RimePortableArchiveError else {
                    return XCTFail("Expected path-alias rejection, got \(error)")
                }
                XCTAssertTrue(message.contains("别名"), message)
            }
        }
    }

    func testImportRejectsTargetChangedWhileArchiveIsStaged() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let phraseURL = target.appendingPathComponent("custom_phrase.txt")
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("archive phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("preview phrase", to: phraseURL)
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let fileManager = MutatingStagedFileManager(targetURL: phraseURL, replacement: "user edit during staging")
        let service = RimePortableArchiveService(fileManager: fileManager)
        let preview = try service.previewImport(from: archive, to: target)

        XCTAssertThrowsError(try service.importArchive(from: archive, to: target, backupRoot: backupRoot, expectedPreview: preview)) { error in
            XCTAssertEqual(error as? RimePortableArchiveError, .targetChanged)
        }
        XCTAssertEqual(try String(contentsOf: phraseURL, encoding: .utf8), "user edit during staging")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
    }

    func testWriteFailureRollsBackFilesAlreadyApplied() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("new skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("old phrase", to: target.appendingPathComponent("custom_phrase.txt"))
        try write("old skin", to: target.appendingPathComponent("squirrel.custom.yaml"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let service = RimePortableArchiveService(fileManager: FailingStagedCopyFileManager(failureNumber: 2))

        XCTAssertThrowsError(try service.importArchive(from: archive, to: target, backupRoot: backupRoot))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "old phrase")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("squirrel.custom.yaml"), encoding: .utf8), "old skin")
        let recoveries = try RimePortableArchiveService().pendingRecoveries(in: backupRoot)
        XCTAssertTrue(recoveries.isEmpty)
    }

    func testRollbackFailureKeepsBackupAndActiveRecoveryRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("new skin", to: source.appendingPathComponent("squirrel.custom.yaml"))
        try write("old phrase", to: target.appendingPathComponent("custom_phrase.txt"))
        try write("old skin", to: target.appendingPathComponent("squirrel.custom.yaml"))
        _ = try RimePortableArchiveService().export(from: source, to: archive)
        let service = RimePortableArchiveService(fileManager: FailingWriteAndRollbackFileManager())

        XCTAssertThrowsError(try service.importArchive(from: archive, to: target, backupRoot: backupRoot)) { error in
            guard case let .incompleteRollback(message) = error as? RimePortableArchiveError else {
                return XCTFail("Expected recoverable rollback failure, got \(error)")
            }
            XCTAssertTrue(message.contains(backupRoot.path))
        }

        let pending = try service.pendingRecoveries(in: backupRoot)
        XCTAssertEqual(pending.count, 1)
        let recoveryService = RimePortableArchiveService()
        try recoveryService.restoreImportFiles(backupID: pending[0].id, in: backupRoot, targetDirectory: target)
        try recoveryService.completeRollback(backupID: pending[0].id, in: backupRoot)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "old phrase")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("squirrel.custom.yaml"), encoding: .utf8), "old skin")
    }

    func testInterruptedImportCanBeDiscoveredAndRolledBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("new phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("old phrase", to: target.appendingPathComponent("custom_phrase.txt"))
        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let report = try service.importArchive(from: archive, to: target, backupRoot: backupRoot)

        XCTAssertEqual(try service.pendingRecoveries(in: backupRoot).map(\.id), [report.backupID])
        try service.restoreImportFiles(backupID: report.backupID, in: backupRoot, targetDirectory: target)

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("custom_phrase.txt"), encoding: .utf8), "old phrase")
        XCTAssertEqual(try service.pendingRecoveries(in: backupRoot).map(\.id), [report.backupID])
        try service.completeRollback(backupID: report.backupID, in: backupRoot)
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testRollbackPreservesEditsMadeAfterInterruptedImport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let phraseURL = target.appendingPathComponent("custom_phrase.txt")
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try write("imported phrase", to: source.appendingPathComponent("custom_phrase.txt"))
        try write("original phrase", to: phraseURL)

        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let report = try service.importArchive(from: archive, to: target, backupRoot: backupRoot)
        try write("new user edit", to: phraseURL)

        XCTAssertThrowsError(try service.restoreImportFiles(backupID: report.backupID, in: backupRoot, targetDirectory: target)) { error in
            guard case let .recoveryConflict(paths) = error as? RimePortableArchiveError else {
                return XCTFail("Expected recovery conflict, got \(error)")
            }
            XCTAssertEqual(paths, "custom_phrase.txt")
        }
        XCTAssertEqual(try String(contentsOf: phraseURL, encoding: .utf8), "new user edit")
        XCTAssertEqual(try service.pendingRecoveries(in: backupRoot).map(\.id), [report.backupID])

        try write("imported phrase", to: phraseURL)
        try service.restoreImportFiles(backupID: report.backupID, in: backupRoot, targetDirectory: target)
        try service.completeRollback(backupID: report.backupID, in: backupRoot)
        XCTAssertEqual(try String(contentsOf: phraseURL, encoding: .utf8), "original phrase")
        XCTAssertTrue(try service.pendingRecoveries(in: backupRoot).isEmpty)
    }

    func testPendingRecoveryScanReportsCorruptJournalWithoutHidingValidTransactions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Rime", isDirectory: true)
        let target = root.appendingPathComponent("target/Rime", isDirectory: true)
        let archive = root.appendingPathComponent("backup.rimevoiceconfig")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let corruptDirectory = backupRoot.appendingPathComponent("import-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptDirectory.appendingPathComponent("transaction.json"))
        try write("imported phrase", to: source.appendingPathComponent("custom_phrase.txt"))

        let service = RimePortableArchiveService()
        _ = try service.export(from: source, to: archive)
        let validReport = try service.importArchive(from: archive, to: target, backupRoot: backupRoot)

        let recoveries = try service.pendingRecoveries(in: backupRoot)

        XCTAssertEqual(recoveries.map(\.id), ["import-corrupt", validReport.backupID].sorted())
        XCTAssertEqual(recoveries.first(where: { $0.id == "import-corrupt" })?.filePaths, [])
        XCTAssertNotNil(recoveries.first(where: { $0.id == "import-corrupt" })?.problem)
        XCTAssertNil(recoveries.first(where: { $0.id == validReport.backupID })?.problem)
    }

    private func writeEmptyPayloadArchive(paths: [String], to url: URL) throws {
        let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let files: [[String: Any]] = paths.sorted().map { path in
            ["relativePath": path, "byteCount": 0, "sha256": emptySHA256, "isExecutable": false]
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["version": 1, "files": files], options: [.sortedKeys])
        var data = Data("RVCONFIG".utf8)
        var version = UInt32(1).bigEndian
        var manifestLength = UInt64(manifest.count).bigEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &manifestLength) { data.append(contentsOf: $0) }
        data.append(manifest)
        try data.write(to: url)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimePortableArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}

private final class FailingStagedCopyFileManager: FileManager {
    private let failureNumber: Int
    private var stagedCopyCount = 0

    init(failureNumber: Int) {
        self.failureNumber = failureNumber
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.path.contains("/.rime-import-stage-") {
            stagedCopyCount += 1
            if stagedCopyCount == failureNumber {
                throw RimeSyncError.unsupportedOperation("模拟导入写入失败")
            }
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class RejectTemporaryArchiveValidationFileManager: FileManager {
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        guard fileName.hasPrefix(".rimevoiceconfig-"), fileName.hasSuffix(".tmp"),
              let size = attributes[.size] as? NSNumber else {
            return attributes
        }
        var invalidAttributes = attributes
        invalidAttributes[.size] = NSNumber(value: size.int64Value + 1)
        return invalidAttributes
    }
}

private final class MutatingStagedFileManager: FileManager {
    private let targetURL: URL
    private let replacement: String
    private var hasMutatedTarget = false

    init(targetURL: URL, replacement: String) {
        self.targetURL = targetURL
        self.replacement = replacement
        super.init()
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if created, !hasMutatedTarget, path.contains("/.rime-import-stage-") {
            hasMutatedTarget = true
            try? Data(replacement.utf8).write(to: targetURL)
        }
        return created
    }
}

private final class FailingWriteAndRollbackFileManager: FileManager {
    private var stagedCopyCount = 0
    private var failedRollbackCopy = false

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.path.contains("/.rime-import-stage-") {
            stagedCopyCount += 1
            if stagedCopyCount == 2 {
                throw RimeSyncError.unsupportedOperation("模拟第二个配置文件写入失败")
            }
        }
        if !failedRollbackCopy, srcURL.path.contains("/files/") {
            failedRollbackCopy = true
            throw RimeSyncError.unsupportedOperation("模拟回滚文件复制失败")
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class PortableArchiveMaintenanceSpy: NativeRimeMaintaining, RimeUserDictionaryMaintaining {
    func syncUserData() throws {}
    func reload() throws {}
    func backupUserDictionary(in rimeDirectory: URL) throws {}
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws {}
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws {}
}

private struct PortableArchiveSyncSpy: RimeSyncEngine {
    func status() throws -> SyncReport { SyncReport() }
    func sync(dryRun: Bool) throws -> SyncReport { SyncReport() }
    func restore(backupID: String) throws {}
}
