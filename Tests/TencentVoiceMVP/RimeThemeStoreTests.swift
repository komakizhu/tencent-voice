import Foundation
import XCTest
@testable import TencentVoiceMVP

final class RimeThemeStoreTests: XCTestCase {
    func testLoadsSlashThemesAndCurrentSelection() throws {
        let fixture = try makeFixture()
        let store = RimeThemeStore(configURL: fixture.configURL, reload: {})

        let snapshot = try store.load()

        XCTAssertEqual(snapshot.selectedThemeID, "blue_reverie")
        XCTAssertEqual(snapshot.selectedDarkThemeID, "blue_reverie_dark")
        XCTAssertEqual(snapshot.themes.map(\.id), ["blue_reverie", "paper", "mint", "midnight"])
        XCTAssertEqual(snapshot.themes.first(where: { $0.id == "paper" })?.displayName, "纸张 / Paper")
        XCTAssertEqual(snapshot.themes.first(where: { $0.id == "paper" })?.darkThemeID, "paper_dark")
    }

    func testSelectUpdatesBothModesPreservesPermissionsAndReloads() async throws {
        let fixture = try makeFixture()
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)[.posixPermissions] as? NSNumber
        var reloadCount = 0
        let store = RimeThemeStore(configURL: fixture.configURL, reload: { reloadCount += 1 })

        let snapshot = try await store.select(themeID: "mint")
        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)[.posixPermissions] as? NSNumber

        XCTAssertEqual(snapshot.selectedThemeID, "mint")
        XCTAssertEqual(snapshot.selectedDarkThemeID, "mint_dark")
        XCTAssertTrue(text.contains("color_scheme: mint"))
        XCTAssertTrue(text.contains("color_scheme_dark: mint_dark"))
        XCTAssertTrue(text.contains("preset_color_schemes/paper"))
        XCTAssertEqual(permissions, originalPermissions)
        XCTAssertEqual(reloadCount, 1)
    }

    func testLegacyNestedThemesRemainReadable() throws {
        let fixture = try makeFixture(legacyThemeMap: true)
        let store = RimeThemeStore(configURL: fixture.configURL, reload: {})

        let snapshot = try store.load()

        XCTAssertEqual(snapshot.themes.map(\.id), ["blue_reverie", "paper", "mint", "midnight"])
    }

    func testUnknownThemeDoesNotReloadOrWrite() async throws {
        let fixture = try makeFixture()
        let before = try Data(contentsOf: fixture.configURL)
        var reloadCount = 0
        let store = RimeThemeStore(configURL: fixture.configURL, reload: { reloadCount += 1 })

        do {
            _ = try await store.select(themeID: "missing")
            XCTFail("选择不存在的主题应该失败")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), before)
        XCTAssertEqual(reloadCount, 0)
    }

    private struct Fixture {
        let configURL: URL
    }

    private func makeFixture(legacyThemeMap: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeThemeStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("squirrel.custom.yaml")
        let contents = legacyThemeMap ? legacyConfiguration : slashConfiguration
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configURL.path)
        return Fixture(configURL: configURL)
    }

    private var slashConfiguration: String {
        """
        patch:
          style:
            color_scheme: blue_reverie
            color_scheme_dark: blue_reverie_dark

          "preset_color_schemes/blue_reverie":
            name: "Blue Reverie"
          "preset_color_schemes/blue_reverie_dark":
            name: "Blue Reverie Dark"
          "preset_color_schemes/paper":
            name: "纸张 / Paper"
          "preset_color_schemes/paper_dark":
            name: "纸张深色 / Paper Dark"
          "preset_color_schemes/mint":
            name: "薄荷 / Mint"
          "preset_color_schemes/mint_dark":
            name: "薄荷深色 / Mint Dark"
          "preset_color_schemes/midnight":
            name: "午夜蓝 / Midnight"
          "preset_color_schemes/midnight_dark":
            name: "午夜蓝深色 / Midnight Dark"
        """
    }

    private var legacyConfiguration: String {
        """
        patch:
          style:
            color_scheme: blue_reverie
            color_scheme_dark: blue_reverie_dark
          preset_color_schemes:
            blue_reverie:
              name: "Blue Reverie"
            blue_reverie_dark:
              name: "Blue Reverie Dark"
            paper:
              name: "纸张 / Paper"
            paper_dark:
              name: "纸张深色 / Paper Dark"
            mint:
              name: "薄荷 / Mint"
            mint_dark:
              name: "薄荷深色 / Mint Dark"
            midnight:
              name: "午夜蓝 / Midnight"
            midnight_dark:
              name: "午夜蓝深色 / Midnight Dark"
        """
    }
}
