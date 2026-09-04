import Foundation
import XCTest
@testable import RimeSyncCore

final class RimeAuditTests: XCTestCase {
    func testOfficialRimeFormulasAndStableIdentity() {
        let decay = RimeScoring.formulaD(d: 0, t: 1_000, da: 200, ta: 800)
        XCTAssertEqual(decay, 200 * exp(-1), accuracy: 0.000_001)

        let score = RimeScoring.formulaP(s: 0, u: 0.1, t: 1_000, d: decay)
        XCTAssertGreaterThan(score, 0)
        XCTAssertNotEqual(RimeUserDictionaryEntry.identity(for: "项目", code: "xiangmu"), RimeUserDictionaryEntry.identity(for: "项目", code: "xm"))
        XCTAssertEqual(RimeUserDictionaryEntry.identity(for: " 项目 ", code: "XIANGMU"), RimeUserDictionaryEntry.identity(for: "项目", code: "xiangmu"))
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

    func testDeleteLearnedCreatesNegativeTombstoneAndPermanentIgnoreIsPersistent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/Rime", isDirectory: true)
        let snapshotURL = shared.appendingPathComponent("rime-userdata/mac/rime_ice.userdb.txt")
        try write("#@/db_name\trime_ice.userdb\nbad\t坏词\tc=2 d=0 t=1\n", to: snapshotURL)
        try write("schema", to: local.appendingPathComponent("rime_ice.schema.yaml"))
        let configuration = SyncConfiguration(localRimeDirectory: local, sharedRoot: shared, installationID: "mac", nodeID: "mac")
        let maintenance = AuditFakeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(configuration: configuration, maintenance: maintenance, reloader: maintenance, ordinarySync: AuditNoopSync())

        let batch = try coordinator.prepareAudit()
        let entry = try XCTUnwrap(batch.entries.first)
        _ = try coordinator.apply(batch: batch, actions: [entry.id: .deleteLearned])

        let tombstoneData = try XCTUnwrap(maintenance.restoredSnapshots.last)
        let tombstone = try RimeSnapshotParser().parse(data: tombstoneData, sourceInstallationID: "mac").snapshot.entries.first
        XCTAssertLessThan(tombstone?.commitCount ?? 0, -2)
        XCTAssertGreaterThan(abs(tombstone?.commitCount ?? 0), 1_000)
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
        let batch = RimeAuditBatch(snapshotDigest: "digest", snapshotDigests: ["mac": "one"], entries: [entry])
        let csv = RimeAuditCSV.export(batch: batch)
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).contains("\"含,逗号\""))
        let proposal = try RimeAuditProposal(batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, entryID: entry.id, action: .promotePermanent, confidence: 0.9, reason: "保留,这是项目名")
        let proposalCSV = RimeAuditCSV.exportProposals([proposal])
        XCTAssertEqual(String(decoding: proposalCSV, as: UTF8.self).components(separatedBy: "\r\n").first, RimeAuditCSV.proposalHeaders.joined(separator: ","))
        let decoded = try RimeAuditCSV.importProposals(data: proposalCSV, batch: batch)
        XCTAssertEqual(decoded, [proposal])
        XCTAssertThrowsError(try RimeAuditProposal(batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, entryID: entry.id, action: .skipOnce, confidence: 0.9, reason: "skip"))
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

private final class AuditFakeMaintenance: NativeRimeMaintaining, RimeUserDictionaryMaintaining {
    var restoredSnapshots: [Data] = []
    func syncUserData() throws {}
    func reload() throws {}
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws {}
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws {
        restoredSnapshots.append(try Data(contentsOf: snapshot))
    }
}
