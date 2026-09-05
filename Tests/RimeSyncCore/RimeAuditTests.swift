import Foundation
import XCTest
@testable import RimeSyncCore

final class RimeAuditTests: XCTestCase {
    func testAuditExporterSupportsTextMarkdownAndJSON() throws {
        let entry = RimeAuditEntry(
            id: "entry-1",
            text: "示例词",
            code: "shi li",
            observations: [:],
            commitCount: 4,
            decay: 2,
            tick: 10,
            effectiveDecay: 1.5,
            rimeScore: 0.25,
            inBaseDictionary: false,
            firstSeenAt: nil,
            lastActivityAt: nil,
            currentStatus: .newRecord
        )
        let batch = RimeAuditBatch(
            batchID: "batch-1",
            snapshotDigest: "digest-1",
            snapshotDigests: ["mac": "digest-1"],
            entries: [entry]
        )

        let txt = try RimeAuditExporter.export(batch: batch, entries: [entry], format: .txt)
        let markdown = try RimeAuditExporter.export(batch: batch, entries: [entry], format: .markdown)
        let json = try RimeAuditExporter.export(batch: batch, entries: [entry], format: .json)

        XCTAssertTrue(String(decoding: txt, as: UTF8.self).contains("示例词\tshi li\t4"))
        XCTAssertTrue(String(decoding: markdown, as: UTF8.self).contains("| 示例词 | shi li |"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["batch_id"] as? String, "batch-1")
        XCTAssertEqual((object["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(RimeAuditExportFormat.markdown.fileExtension, "md")
    }

    func testOfficialRimeFormulasAndStableIdentity() {
        let decay = RimeScoring.formulaD(d: 0, t: 1_000, da: 200, ta: 800)
        XCTAssertEqual(decay, 200 * exp(-1), accuracy: 0.000_001)

        let score = RimeScoring.formulaP(s: 0, u: 0.1, t: 1_000, d: decay)
        XCTAssertGreaterThan(score, 0)
        XCTAssertNotEqual(RimeUserDictionaryEntry.identity(for: "项目", code: "xiangmu"), RimeUserDictionaryEntry.identity(for: "项目", code: "xm"))
        XCTAssertEqual(RimeUserDictionaryEntry.identity(for: " 项目 ", code: "XIANGMU"), RimeUserDictionaryEntry.identity(for: "项目", code: "xiangmu"))
    }

    func testRefreshingPublishedSnapshotsDoesNotRunSyncOrBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=2 d=0 t=1\n", to: shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt"))
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AuditNoopSync()
        )

        let batch = try coordinator.refreshAuditFromPublishedSnapshots()

        XCTAssertEqual(batch.entries.count, 1)
        XCTAssertTrue(maintenance.calls.isEmpty)
        XCTAssertNil(try coordinator.syncMetadata().latestRecord)
    }

    func testSyncUserDictionaryRunsNativeSyncAndRecordsLastSync() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=2 d=0 t=1\n", to: shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt"))
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let synchronizedAt = Date(timeIntervalSince1970: 1234)
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AuditNoopSync(),
            now: { synchronizedAt }
        )

        let report = try coordinator.syncUserDictionary()
        let metadata = try coordinator.syncMetadata()

        XCTAssertEqual(maintenance.calls, ["sync", "capture"])
        XCTAssertEqual(report.entryCount, 1)
        XCTAssertEqual(metadata.records["mac"]?.installationID, "mac")
        XCTAssertEqual(metadata.records["mac"]?.synchronizedAt, synchronizedAt)
        XCTAssertEqual(metadata.records["mac"]?.backupID, report.backupID)
        XCTAssertEqual(metadata.records["mac"]?.snapshotDigests["mac"], report.snapshotDigests["mac"])
    }

    func testAuditUsesMaximumCommitCountAcrossNodesWithoutSumming() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=7 d=0 t=1\n", to: shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt"))
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=9 d=0 t=1\n", to: shared.appendingPathComponent("rime-userdata/mac2/rime_ice.userdb.txt"))
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac2", nodeID: "mac2")
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())

        let batch = try coordinator.prepareAudit()

        let entry = try XCTUnwrap(batch.entries.first)
        XCTAssertEqual(entry.commitCount, 9)
        XCTAssertEqual(entry.observations["mac"]?.commitCount, 7)
        XCTAssertEqual(entry.observations["mac2"]?.commitCount, 9)
    }

    func testFirstAuditOnlyCreatesBaselineAndPromotionUsesStaticWeightOne() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=12 d=0 t=1\nhao\t好\tc=3 d=0 t=2\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())

        let first = try coordinator.prepareAudit()
        XCTAssertTrue(first.isInitialBaseline)
        XCTAssertTrue(maintenance.restoredSnapshots.isEmpty)
        XCTAssertTrue(try coordinator.reviewState().initialized)

        let promoted = try XCTUnwrap(first.entries.first(where: { $0.text == "你" }))
        let report = try coordinator.apply(batch: first, actions: [promoted.id: .promotePermanent])
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertFalse(report.initialRuntimeRebuilt)
        let managed = try String(contentsOf: local.appendingPathComponent(RimeManagedDictionary.fileName))
        XCTAssertTrue(managed.contains("你\tni\t1"))
        XCTAssertFalse(managed.contains("你\tni\t12"))
        XCTAssertTrue(maintenance.restoredSnapshots.isEmpty)
    }

    func testLegacyManagedDictionaryMergesWithPartiallyInitializedState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        try write("#@/db_name\trime_ice.userdb\nni\t示例\tc=1 d=0 t=1\n", to: shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt"))
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        try write("---\nname: rime_managed\n...\n旧词\tjiu ci\t1\n", to: local.appendingPathComponent(RimeManagedDictionary.fileName))

        let existing = RimeManagedEntryState(text: "已有", code: "yi you", sourceFrequencies: ["manual": 1])
        let state = RimeReviewState(initialized: true, entries: [existing.identity: existing])
        try RimeReviewStore(url: shared.appendingPathComponent("config/rime-review-state.json")).save(state)

        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AuditNoopSync()
        )

        _ = try coordinator.prepareAudit()

        let migrated = try coordinator.reviewState()
        XCTAssertNotNil(migrated.entries[RimeUserDictionaryEntry.identity(for: "旧词", code: "jiu ci")])
        let managed = try String(contentsOf: local.appendingPathComponent(RimeManagedDictionary.fileName))
        XCTAssertTrue(managed.contains("旧词\tjiu ci\t1"))
    }

    func testDeleteLearnedCreatesNegativeTombstoneAndPermanentIgnoreIsPersistent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nbad\t坏词\tc=2 d=0 t=1\nzao\t噪音\tc=1 d=0 t=2\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())

        let batch = try coordinator.prepareAudit()
        let deletedEntry = try XCTUnwrap(batch.entries.first(where: { $0.text == "坏词" }))
        let ignoredEntry = try XCTUnwrap(batch.entries.first(where: { $0.text == "噪音" }))
        _ = try coordinator.apply(batch: batch, actions: [deletedEntry.id: .deleteLearned])
        _ = try coordinator.apply(batch: batch, actions: [ignoredEntry.id: .ignorePermanent])

        let tombstoneData = try XCTUnwrap(maintenance.restoredSnapshots.last)
        let tombstone = try RimeSnapshotParser().parse(data: tombstoneData, sourceInstallationID: "mac").snapshot.entries.first
        XCTAssertLessThan(tombstone?.commitCount ?? 0, -2)
        XCTAssertGreaterThan(abs(tombstone?.commitCount ?? 0), 1_000)
        let state = try coordinator.reviewState()
        XCTAssertTrue(state.permanentIgnoredIDs.contains(ignoredEntry.id))
        let managed = try String(contentsOf: local.appendingPathComponent(RimeManagedDictionary.fileName))
        XCTAssertFalse(managed.contains("噪音\tzao"))
    }

    func testFilterBandsUseFiveFixedOptionsAndHideStaleNoiseByDefault() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entries = (0..<4).map { index in
            RimeAuditEntry(
                id: "\(index)", text: index == 0 ? "A" : "词\(index)", code: "code\(index)", observations: [:],
                commitCount: [1, 3, 10, 100][index], decay: 100, tick: 1, effectiveDecay: Double(index + 1),
                rimeScore: Double(index + 1), inBaseDictionary: false, firstSeenAt: now, lastActivityAt: now,
                currentStatus: .newRecord, isNoise: index == 0, isStale: index == 0
            )
        }
        let result = RimeAuditFilter.filter(entries, query: RimeAuditQuery(view: .all, commitBand: .atLeast10), now: now)
        XCTAssertEqual(result.entries.map(\.commitCount), [100, 10])
        XCTAssertEqual(RimeCommitCountBand.allCases.map(\.minimum), [0, 3, 10, 30, 100])
        XCTAssertEqual(RimeHeatBand.allCases.count, 5)
        XCTAssertEqual(RimeRecentActivityBand.allCases.count, 5)
    }

    func testAuditCSVQuotesAndProposalValidation() throws {
        let entry = RimeAuditEntry(id: "id", text: "含,逗号", code: "han", observations: [:], commitCount: 2, decay: 1, tick: 3, effectiveDecay: 1, rimeScore: 2, inBaseDictionary: false, firstSeenAt: nil, lastActivityAt: nil, currentStatus: .newRecord)
        let otherEntry = RimeAuditEntry(id: "other", text: "其他", code: "qi ta", observations: [:], commitCount: 1, decay: 1, tick: 2, effectiveDecay: 1, rimeScore: 1, inBaseDictionary: false, firstSeenAt: nil, lastActivityAt: nil, currentStatus: .dynamic)
        let batch = RimeAuditBatch(snapshotDigest: "digest", snapshotDigests: ["mac": "one"], entries: [entry, otherEntry])
        let csv = RimeAuditCSV.export(batch: batch)
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).contains("\"含,逗号\""))
        let filteredCSV = String(decoding: RimeAuditCSV.export(batch: batch, entries: [entry]), as: UTF8.self)
        XCTAssertTrue(filteredCSV.contains("含,逗号"))
        XCTAssertFalse(filteredCSV.contains("其他"))
        let proposal = try RimeAuditProposal(batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, entryID: entry.id, action: .promotePermanent, confidence: 0.9, reason: "保留,这是项目名")
        let proposalCSV = RimeAuditCSV.exportProposals([proposal])
        XCTAssertEqual(String(decoding: proposalCSV, as: UTF8.self).components(separatedBy: "\r\n").first, RimeAuditCSV.proposalHeaders.joined(separator: ","))
        let decoded = try RimeAuditCSV.importProposals(data: proposalCSV, batch: batch)
        XCTAssertEqual(decoded, [proposal])
        let proposalCSVWithoutFinalNewline = Data(String(decoding: proposalCSV, as: UTF8.self).dropLast().utf8)
        XCTAssertEqual(try RimeAuditCSV.importProposals(data: proposalCSVWithoutFinalNewline, batch: batch), [proposal])
        let replacement = try RimeAuditProposal(
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            entryID: entry.id,
            action: .replaceEntry,
            confidence: 0.95,
            reason: "替换,保留原始热度",
            replacementText: "新词",
            replacementCode: "xin ci"
        )
        let replacementCSV = RimeAuditCSV.exportProposals([replacement])
        XCTAssertEqual(try RimeAuditCSV.importProposals(data: replacementCSV, batch: batch), [replacement])
        let legacyCSV = Data((RimeAuditCSV.proposalHeaders.dropLast(2).joined(separator: ",") + "\r\n" +
            "2,\(batch.batchID),\(batch.snapshotDigest),\(entry.id),promote_permanent,0.8,legacy\r\n").utf8)
        XCTAssertEqual(try RimeAuditCSV.importProposals(data: legacyCSV, batch: batch).first?.action, .promotePermanent)
        XCTAssertThrowsError(try RimeAuditProposal(batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, entryID: entry.id, action: .skipOnce, confidence: 0.9, reason: "skip"))
    }

    func testReplaceProposalJSONRoundTripsAndLegacyProposalStillDecodes() throws {
        let proposal = try RimeAuditProposal(
            batchID: "batch-1",
            snapshotDigest: "digest-1",
            entryID: "old-id",
            action: .replaceEntry,
            confidence: 0.97,
            reason: "规范专有词大小写",
            replacementText: "Dubstep",
            replacementCode: "dubstep"
        )
        let encoded = try JSONEncoder.rimeEncoder.encode(proposal)
        let decoded = try JSONDecoder.rimeDecoder.decode(RimeAuditProposal.self, from: encoded)
        XCTAssertEqual(decoded, proposal)
        XCTAssertEqual(decoded.action, .replaceEntry)
        XCTAssertEqual(decoded.replacementText, "Dubstep")
        XCTAssertEqual(decoded.replacementCode, "dubstep")

        let legacy = Data("""
        {"batchID":"batch-1","snapshotDigest":"digest-1","entryID":"old-id","action":"promote_permanent","confidence":0.8,"reason":"legacy"}
        """.utf8)
        let legacyDecoded = try JSONDecoder.rimeDecoder.decode(RimeAuditProposal.self, from: legacy)
        XCTAssertEqual(legacyDecoded.source, "ai")
        XCTAssertNil(legacyDecoded.replacementText)
        XCTAssertNil(legacyDecoded.replacementCode)
    }

    func testReplaceEntryMigratesChineseAndEnglishUserdbDataAndIsIdempotent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        try write("#@/db_name\trime_ice.userdb\nzhan lian\t静默粘连\tc=12 d=4.5 t=17\ndubstep\tDUBSTEP\tc=8 d=2.25 t=23\n", to: shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt"))
        try write("#@/db_name\trime_ice.userdb\nzhan lian\t静默粘连\tc=7 d=1.5 t=11\n", to: shared.appendingPathComponent("rime-userdata/mac2-main/rime_ice.userdb.txt"))
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))

        let maintenance = AuditFakeMaintenance()
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let coordinator = RimeReviewSyncCoordinator(
            configuration: configuration,
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AuditNoopSync()
        )
        let batch = try coordinator.prepareAudit()
        let chinese = try XCTUnwrap(batch.entries.first(where: { $0.text == "静默粘连" }))
        let english = try XCTUnwrap(batch.entries.first(where: { $0.text == "DUBSTEP" }))
        let proposals = [
            try RimeAuditProposal(
                batchID: batch.batchID,
                snapshotDigest: batch.snapshotDigest,
                entryID: chinese.id,
                action: .replaceEntry,
                confidence: 0.99,
                reason: "术语修正",
                replacementText: "筋膜粘连",
                replacementCode: "jin mo zhan lian"
            ),
            try RimeAuditProposal(
                batchID: batch.batchID,
                snapshotDigest: batch.snapshotDigest,
                entryID: english.id,
                action: .replaceEntry,
                confidence: 0.98,
                reason: "统一大小写",
                replacementText: "Dubstep",
                replacementCode: "dubstep"
            )
        ]

        let preview = try coordinator.submitProposals(proposals, for: batch)
        XCTAssertEqual(preview.countsByAction["replace_entry"], 2)
        XCTAssertTrue(preview.replacements.allSatisfy { $0.generatedByReplaceEntry && $0.willBecomePermanent })
        XCTAssertEqual(try coordinator.reviewState().proposals[batch.batchID], proposals)
        let restarted = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())
        XCTAssertEqual(try restarted.reviewState().proposals[batch.batchID], proposals)

        let report = try coordinator.apply(proposals: proposals, for: batch)
        XCTAssertEqual(report.replacedCount, 2)
        let state = try coordinator.reviewState()
        let chineseTargetID = RimeUserDictionaryEntry.identity(for: "筋膜粘连", code: "jin mo zhan lian")
        let englishTargetID = RimeUserDictionaryEntry.identity(for: "Dubstep", code: "dubstep")
        XCTAssertNil(state.entries[chinese.id])
        XCTAssertNil(state.entries[english.id])
        XCTAssertEqual(state.entries[chineseTargetID]?.sourceFrequencies["mac"], 12)
        XCTAssertEqual(state.entries[chineseTargetID]?.sourceFrequencies["mac2-main"], 7)
        XCTAssertEqual(state.nodeObservations["mac"]?[chineseTargetID]?.decay, 4.5)
        XCTAssertEqual(state.nodeObservations["mac"]?[chineseTargetID]?.tick, 17)
        XCTAssertEqual(state.nodeObservations["mac2-main"]?[chineseTargetID]?.commitCount, 7)
        XCTAssertEqual(state.nodeObservations["mac"]?[englishTargetID]?.commitCount, 8)
        XCTAssertEqual(state.nodeObservations["mac"]?[englishTargetID]?.text, "Dubstep")
        XCTAssertEqual(state.replacementRecords[chinese.id]?.sourceEntries["mac"]?.commitCount, 12)
        XCTAssertEqual(state.replacementRecords[english.id]?.sourceEntries["mac"]?.decay, 2.25)
        XCTAssertEqual(state.completedActions["\(batch.batchID):mac:\(chinese.id)"]?.status, .completed)
        XCTAssertEqual(state.pendingActions[chinese.id]?.action, .replaceEntry)
        XCTAssertEqual(state.pendingActions[chinese.id]?.replacementText, "筋膜粘连")
        XCTAssertEqual(state.pendingActions[chinese.id]?.replacementCode, "jin mo zhan lian")

        let payload = try XCTUnwrap(maintenance.restoredSnapshots.last)
        let payloadEntries = try RimeSnapshotParser().parse(data: payload, sourceInstallationID: "mac").snapshot.entries
        let migratedChinese = try XCTUnwrap(payloadEntries.first(where: { $0.text == "筋膜粘连" }))
        let migratedEnglish = try XCTUnwrap(payloadEntries.first(where: { $0.text == "Dubstep" }))
        XCTAssertEqual(migratedChinese.commitCount, 12)
        XCTAssertEqual(migratedChinese.decay, 4.5)
        XCTAssertEqual(migratedChinese.tick, 17)
        XCTAssertEqual(migratedEnglish.commitCount, 8)
        XCTAssertEqual(migratedEnglish.decay, 2.25)
        XCTAssertEqual(migratedEnglish.tick, 23)
        XCTAssertTrue(payloadEntries.contains { $0.identity == chinese.id && $0.isTombstone })
        XCTAssertTrue(payloadEntries.contains { $0.identity == english.id && $0.isTombstone })

        let restoreCount = maintenance.restoredSnapshots.count
        let restartedAfterApply = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())
        let refreshedBatch = try restartedAfterApply.refreshAuditFromPublishedSnapshots()
        XCTAssertTrue(refreshedBatch.entries.first(where: { $0.id == chineseTargetID })?.generatedByReplaceEntry == true)
        let second = try restartedAfterApply.apply(proposals: proposals, for: batch)
        XCTAssertEqual(second.replacedCount, 0)
        XCTAssertEqual(second.backupID, report.backupID)
        XCTAssertEqual(maintenance.restoredSnapshots.count, restoreCount)

        let remoteLocal = root.appendingPathComponent("local2/Rime", isDirectory: true)
        try write("schema", to: remoteLocal.appendingPathComponent("rime_ice.schema.yaml"))
        let remoteMaintenance = AuditFakeMaintenance()
        let remoteConfiguration = SyncConfiguration(
            localRimeDirectory: remoteLocal,
            sharedRoot: shared,
            installationID: "mac2-main",
            nodeID: "mac2"
        )
        let remoteCoordinator = RimeReviewSyncCoordinator(
            configuration: remoteConfiguration,
            maintenance: remoteMaintenance,
            reloader: remoteMaintenance,
            ordinarySync: AuditNoopSync()
        )
        let remoteBatch = try remoteCoordinator.refreshAuditFromPublishedSnapshots()
        XCTAssertTrue(remoteBatch.entries.first(where: { $0.id == chineseTargetID })?.generatedByReplaceEntry == true)
        let remotePayload = try XCTUnwrap(remoteMaintenance.restoredSnapshots.last)
        let remoteEntries = try RimeSnapshotParser().parse(data: remotePayload, sourceInstallationID: "mac2-main").snapshot.entries
        let remoteChinese = try XCTUnwrap(remoteEntries.first(where: { $0.text == "筋膜粘连" }))
        XCTAssertEqual(remoteChinese.commitCount, 7)
        XCTAssertEqual(remoteChinese.decay, 1.5)
        XCTAssertEqual(remoteChinese.tick, 11)
        XCTAssertTrue(remoteEntries.contains { $0.identity == chinese.id && $0.isTombstone })
        XCTAssertEqual(try remoteCoordinator.reviewState().completedActions["\(batch.batchID):mac2:\(chinese.id)"]?.status, .completed)
        XCTAssertNil(try remoteCoordinator.reviewState().pendingActions[chinese.id])
    }

    func testReplaceEntryRejectsExistingTargetAndExpiredProposal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nold\t旧词\tc=3 d=0 t=1\nnew\t新词\tc=2 d=0 t=1\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let maintenance = AuditFakeMaintenance()
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let coordinator = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())
        let batch = try coordinator.prepareAudit()
        let old = try XCTUnwrap(batch.entries.first(where: { $0.text == "旧词" }))
        let existingTarget = try RimeAuditProposal(
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            entryID: old.id,
            action: .replaceEntry,
            confidence: 1,
            reason: "冲突测试",
            replacementText: "新词",
            replacementCode: "new"
        )
        XCTAssertThrowsError(try coordinator.apply(proposals: [existingTarget], for: batch)) { error in
            XCTAssertTrue(error.localizedDescription.contains("目标词条已存在"))
        }

        let expired = try RimeAuditProposal(
            batchID: "expired-batch",
            snapshotDigest: "expired-digest",
            entryID: old.id,
            action: .replaceEntry,
            confidence: 1,
            reason: "过期测试",
            replacementText: "另一个词",
            replacementCode: "ling yi ge ci"
        )
        XCTAssertThrowsError(try coordinator.apply(proposals: [expired], for: batch)) { error in
            XCTAssertTrue(error.localizedDescription.contains("批次或快照已过期"))
        }
        XCTAssertTrue(maintenance.restoredSnapshots.count <= 1)
    }

    func testReplaceEntryFailureRollsBackAndPersistsFailureRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nold\t旧词\tc=3 d=1 t=4\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let maintenance = AuditFakeMaintenance()
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let reader = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())
        let batch = try reader.prepareAudit()
        let old = try XCTUnwrap(batch.entries.first)
        let proposal = try RimeAuditProposal(
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            entryID: old.id,
            action: .replaceEntry,
            confidence: 0.9,
            reason: "回滚测试",
            replacementText: "新词",
            replacementCode: "xin ci"
        )
        let failing = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditFailingSync())

        XCTAssertThrowsError(try failing.apply(proposals: [proposal], for: batch)) { error in
            XCTAssertTrue(error.localizedDescription.contains("配置同步失败"))
        }
        let state = try failing.reviewState()
        XCTAssertNil(state.entries[RimeUserDictionaryEntry.identity(for: "新词", code: "xin ci")])
        XCTAssertEqual(state.replacementRecords[old.id]?.status, .failed)
        XCTAssertTrue(state.replacementRecords[old.id]?.errorMessage?.contains("配置同步失败") == true)
        XCTAssertTrue(try String(contentsOf: snapshotURL).contains("旧词"))
        XCTAssertFalse(try String(contentsOf: local.appendingPathComponent(RimeManagedDictionary.fileName)).contains("新词\txin ci"))
    }

    func testActivityDateChangesOnlyWhenCommitCountGrows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=1 d=0 t=1\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        var clock = Date(timeIntervalSince1970: 1_000)
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AuditNoopSync(),
            now: { clock }
        )

        let first = try coordinator.prepareAudit()
        XCTAssertNil(first.entries.first?.lastActivityAt)

        clock = Date(timeIntervalSince1970: 2_000)
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=1 d=4 t=99\n", to: snapshotURL)
        let second = try coordinator.prepareAudit()
        XCTAssertNil(second.entries.first?.lastActivityAt)

        clock = Date(timeIntervalSince1970: 3_000)
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=2 d=4 t=99\n", to: snapshotURL)
        let third = try coordinator.prepareAudit()
        XCTAssertEqual(third.entries.first?.lastActivityAt, clock)
    }

    func testBaseDictionaryIndexCacheInvalidatesByStaticDictionaryDigest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("""
        ---
        name: rime_ice
        import_tables:
          - extra
        ...
        """, to: root.appendingPathComponent("rime_ice.dict.yaml"))
        let dictionary = root.appendingPathComponent("extra.dict.yaml")
        try write("旧词\tjiu ci\t1\n", to: dictionary)
        let cache = RimeBaseDictionaryIndexCache()
        let first = try cache.index(for: root)
        XCTAssertTrue(first.contains(text: "旧词", code: "jiu ci"))
        XCTAssertFalse(first.contains(text: "新词", code: "xin ci"))

        try write("新词\txin ci\t1\n", to: dictionary)
        let second = try cache.index(for: root)
        XCTAssertFalse(second.contains(text: "旧词", code: "jiu ci"))
        XCTAssertTrue(second.contains(text: "新词", code: "xin ci"))
    }

    func testBaseDictionaryIndexDoesNotFollowImportsOutsideRimeDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rime = root.appendingPathComponent("Rime", isDirectory: true)
        try write("---\nname: rime_ice\nimport_tables:\n  - ../outside\n...\n", to: rime.appendingPathComponent("rime_ice.dict.yaml"))
        try write("外部词\twai bu ci\t1\n", to: root.appendingPathComponent("outside.dict.yaml"))

        let index = try RimeBaseDictionaryIndex.build(from: rime)

        XCTAssertFalse(index.contains(text: "外部词", code: "wai bu ci"))
    }

    func testCommitGrowthAfterDeleteApprovalRequiresManualReview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let macLocal = root.appendingPathComponent("mac/Rime", isDirectory: true)
        let mac2Local = root.appendingPathComponent("mac2/Rime", isDirectory: true)
        let macSnapshot = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        let mac2Snapshot = shared.appendingPathComponent("rime-userdata/mac2-main/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nbad\t坏词\tc=2 d=0 t=1\n", to: macSnapshot)
        try write("#@/db_name\trime_ice.userdb\nbad\t坏词\tc=2 d=0 t=1\n", to: mac2Snapshot)
        try write("schema", to: macLocal.appendingPathComponent("rime_ice.schema.yaml"))
        try write("schema", to: mac2Local.appendingPathComponent("rime_ice.schema.yaml"))
        let macMaintenance = AuditFakeMaintenance()
        let macCoordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: macLocal, sharedRoot: shared, installationID: "mac", nodeID: "mac"),
            maintenance: macMaintenance,
            reloader: macMaintenance,
            ordinarySync: AuditNoopSync()
        )
        let batch = try macCoordinator.prepareAudit()
        let entry = try XCTUnwrap(batch.entries.first)
        _ = try macCoordinator.apply(batch: batch, actions: [entry.id: .deleteLearned])

        try write("#@/db_name\trime_ice.userdb\nbad\t坏词\tc=3 d=0 t=1\n", to: mac2Snapshot)
        let mac2Maintenance = AuditFakeMaintenance()
        let mac2Coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: mac2Local, sharedRoot: shared, installationID: "mac2-main", nodeID: "mac2"),
            maintenance: mac2Maintenance,
            reloader: mac2Maintenance,
            ordinarySync: AuditNoopSync()
        )
        let updated = try mac2Coordinator.prepareAudit()

        XCTAssertEqual(updated.entries.first?.currentStatus, .manualReview)
        XCTAssertTrue(mac2Maintenance.restoredSnapshots.isEmpty)
    }

    func testProposalSubmissionRejectsChangedCurrentSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=1 d=0 t=1\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac"),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AuditNoopSync()
        )
        let batch = try coordinator.prepareAudit()
        let entry = try XCTUnwrap(batch.entries.first)
        let proposal = try RimeAuditProposal(
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            entryID: entry.id,
            action: .keepDynamic,
            confidence: 0.8,
            reason: "test"
        )
        try write("#@/db_name\trime_ice.userdb\nni\t你\tc=2 d=0 t=1\n", to: snapshotURL)

        XCTAssertThrowsError(try coordinator.submitProposals([proposal], for: batch)) { error in
            XCTAssertTrue(error.localizedDescription.contains("快照已变化"))
        }
    }

    func testApplyFailureRestoresSharedReviewStateFromBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        try write("#@/db_name\trime_ice\nni\t示例\tc=1 d=0 t=1\n", to: shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt"))
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let maintenance = AuditFakeMaintenance()
        let reader = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())
        let batch = try reader.prepareAudit()
        let entry = try XCTUnwrap(batch.entries.first)

        let failing = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditFailingSync())
        XCTAssertThrowsError(try failing.apply(batch: batch, actions: [entry.id: .promotePermanent]))
        XCTAssertNil(try failing.reviewState().entries[entry.id])
        let managed = try String(contentsOf: local.appendingPathComponent(RimeManagedDictionary.fileName))
        XCTAssertFalse(managed.contains("示例\tni"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RimeAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private final class AuditNoopSync: RimeSyncEngine {
    func status() throws -> SyncReport { SyncReport() }
    func sync(dryRun: Bool) throws -> SyncReport { SyncReport() }
    func restore(backupID: String) throws {}
}

private final class AuditFailingSync: RimeSyncEngine {
    func status() throws -> SyncReport { SyncReport() }
    func sync(dryRun: Bool) throws -> SyncReport { throw RimeSyncError.unsupportedOperation("模拟配置同步失败") }
    func restore(backupID: String) throws {}
}

private final class AuditFakeMaintenance: NativeRimeMaintaining, RimeUserDictionaryMaintaining {
    var restoredSnapshots: [Data] = []
    var calls: [String] = []
    func syncUserData() throws { calls.append("sync") }
    func reload() throws { calls.append("reload") }
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws { calls.append("capture") }
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws {
        restoredSnapshots.append(try Data(contentsOf: snapshot))
    }
}
