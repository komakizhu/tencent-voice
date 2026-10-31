import AppKit
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class StatusMenuBarDisplayTests: XCTestCase {
    func testStatusSlotDoesNotMoveWhenTimerGrowsOrRecordingStateChanges() throws {
        _ = NSApplication.shared
        let controller = StatusMenuController(applicationStatusImageURL: originalApplicationImageURL)
        var snapshot = makeSnapshot(state: .idle, isCapturing: false)
        controller.configureRecordingDisplay { snapshot }
        controller.install()
        defer { controller.uninstall() }
        let item = try XCTUnwrap(controller.statusItem)
        let button = try XCTUnwrap(item.button)
        let initialWidth = item.length

        for duration in [0, 9, 10, 99, 100, 999, 1_000, 3_599, 3_600, 86_400] {
            snapshot = makeSnapshot(duration: Double(duration))
            controller.update(recordingState: .listening)
            XCTAssertEqual(controller.statusButtonTitle, "\(duration)s")
            XCTAssertEqual(item.length, initialWidth)
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertEqual(button.image?.size.height, 18)
            XCTAssertLessThanOrEqual(try XCTUnwrap(button.cell).cellSize.width, item.length)
        }

        for mode in MenuBarDisplayMode.allCases {
            controller.update(menuBarDisplayMode: mode)
            for state in states {
                for capturing in [false, true] {
                    snapshot = makeSnapshot(state: state, isCapturing: capturing)
                    controller.update(recordingState: state)
                    XCTAssertEqual(item.length, initialWidth, "切换风格和状态不能挤动旁边图标")
                    XCTAssertNotNil(button.image)
                    XCTAssertTrue(button.title.isEmpty)
                    XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true)
                }
            }
        }
    }

    func testAllModesHaveOnlyReadyAndRecordingVisuals() throws {
        _ = NSApplication.shared
        let controller = StatusMenuController(applicationStatusImageURL: originalApplicationImageURL)
        var snapshot = makeSnapshot(state: .idle, isCapturing: false)
        controller.configureRecordingDisplay { snapshot }
        controller.install()
        defer { controller.uninstall() }
        let button = try XCTUnwrap(controller.statusItem?.button)

        for mode in MenuBarDisplayMode.allCases {
            controller.update(menuBarDisplayMode: mode)
            snapshot = makeSnapshot(state: .idle, isCapturing: false)
            controller.update(recordingState: .idle)
            let ready = try XCTUnwrap(renderButton(button).tiffRepresentation)
            for state in states {
                snapshot = makeSnapshot(state: state, isCapturing: false, duration: 61)
                controller.update(recordingState: state)
                XCTAssertEqual(controller.statusButtonImageStyle, .application)
                XCTAssertEqual(controller.statusButtonTitle, "")
                XCTAssertEqual(renderButton(button).tiffRepresentation, ready, "未采集时必须直接显示未录音样式")
            }
            for state in [SessionState.connecting, .listening, .recovering, .stopping] {
                snapshot = makeSnapshot(state: state, isCapturing: true)
                controller.update(recordingState: state)
                let expected: StatusButtonImageStyle
                switch mode {
                case .icon: expected = .recording
                case .timer: expected = .timer
                case .waveform: expected = .waveform
                }
                XCTAssertEqual(controller.statusButtonImageStyle, expected)
            }
        }
    }

    func testRecordingMarksStayRedAndWaveformStaysMonochromeInBothAppearances() throws {
        _ = NSApplication.shared
        let controller = StatusMenuController(applicationStatusImageURL: originalApplicationImageURL)
        var snapshot = makeSnapshot(rms: 0)
        controller.configureRecordingDisplay { snapshot }
        controller.install()
        defer { controller.uninstall() }
        let button = try XCTUnwrap(controller.statusItem?.button)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            button.appearance = appearance
            for mode in MenuBarDisplayMode.allCases {
                snapshot = makeSnapshot(rms: 0)
                var rendered = NSImage()
                appearance.performAsCurrentDrawingAppearance {
                    controller.update(menuBarDisplayMode: mode)
                    controller.update(recordingState: .listening)
                    rendered = renderButton(button)
                }
                let bitmap = try bitmap(rendered)
                XCTAssertGreaterThan(visiblePixelCount(bitmap), 0, "静音时录音显示也不能消失")
                if mode == .waveform {
                    XCTAssertTrue(try XCTUnwrap(button.image).isTemplate)
                    XCTAssertEqual(redPixelCount(bitmap), 0, "波形必须保持系统黑白")
                    let silentPixels = try visiblePixelCount(self.bitmap(XCTUnwrap(button.image)))
                    snapshot = makeSnapshot(rms: 0.08)
                    appearance.performAsCurrentDrawingAppearance {
                        controller.update(recordingState: .listening)
                    }
                    XCTAssertGreaterThan(try visiblePixelCount(self.bitmap(XCTUnwrap(button.image))), silentPixels)
                } else {
                    XCTAssertFalse(try XCTUnwrap(button.image).isTemplate)
                    XCTAssertGreaterThan(redPixelCount(bitmap), 0)
                }
            }
        }
    }

    func testTimerDotAndDigitsShareOneHorizontalAxisForEveryDigitCount() throws {
        _ = NSApplication.shared
        let controller = StatusMenuController(applicationStatusImageURL: originalApplicationImageURL)
        var snapshot = makeSnapshot()
        controller.configureRecordingDisplay { snapshot }
        controller.install()
        defer { controller.uninstall() }
        let button = try XCTUnwrap(controller.statusItem?.button)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            button.appearance = appearance
            for duration in [0, 9, 10, 61, 99, 100, 999, 1_000, 9_999, 10_000, 86_400] {
                snapshot = makeSnapshot(duration: Double(duration))
                var rendered = NSImage()
                appearance.performAsCurrentDrawingAppearance {
                    controller.update(recordingState: .listening)
                    rendered = renderButton(button)
                }
                let bitmap = try self.bitmap(rendered)
                let red = try pixelBounds(bitmap, matching: isRed)
                let text = try pixelBounds(bitmap) { color in
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    return max(r, g, b) - min(r, g, b) < 0.04
                        && (name == .aqua ? r < 0.4 : r > 0.6)
                }
                let axis = CGFloat(bitmap.pixelsHigh) / 2
                XCTAssertEqual(red.midY, text.midY, accuracy: 0.5, "\(duration)s 红点与数字中心必须对齐（像素）")
                XCTAssertEqual(red.midY, axis, accuracy: 0.5, "计时整体必须对齐公共横轴（像素）")
                XCTAssertEqual(text.midY, axis, accuracy: 0.5, "数字必须对齐公共横轴（像素）")
            }
        }
    }

    func testRecordingStylesShareOneHorizontalAxisAndPreviewKeepsOriginalIdleIcon() throws {
        _ = NSApplication.shared
        let controller = StatusMenuController(applicationStatusImageURL: originalApplicationImageURL)
        var snapshot = makeSnapshot()
        controller.configureRecordingDisplay { snapshot }
        controller.install()
        defer { controller.uninstall() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        var previews: [[NSImage]] = []

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            button.appearance = appearance
            for capturing in [false, true] {
                var row: [NSImage] = []
                for mode in [MenuBarDisplayMode.icon, .timer, .waveform] {
                    snapshot = makeSnapshot(state: capturing ? .listening : .idle, isCapturing: capturing)
                    var rendered = NSImage()
                    appearance.performAsCurrentDrawingAppearance {
                        controller.update(menuBarDisplayMode: mode)
                        controller.update(recordingState: snapshot.state)
                        rendered = renderButton(button)
                    }
                    let bitmap = try self.bitmap(rendered)
                    let bounds = try pixelBounds(bitmap) { color in
                        let brightest = max(color.redComponent, color.greenComponent, color.blueComponent)
                        return name == .aqua ? (brightest < 0.5 || self.isRed(color)) : brightest > 0.6
                    }
                    if capturing {
                        XCTAssertEqual(bounds.midY, CGFloat(bitmap.pixelsHigh) / 2, accuracy: 0.5,
                                       "\(mode) 录音中的三种风格必须共享同一水平中心线（像素）")
                    } else {
                        let original = try XCTUnwrap(NSImage(contentsOf: originalApplicationImageURL))
                        original.size = NSSize(width: 18, height: 18)
                        original.isTemplate = true
                        XCTAssertEqual(button.image?.tiffRepresentation, original.tiffRepresentation,
                                       "未录音图标必须直接使用原图，不得重新绘制或移动内容")
                    }
                    row.append(rendered)
                }
                previews.append(row)
            }
        }
        if let path = ProcessInfo.processInfo.environment["TVMVP_STATUS_PREVIEW_PATH"] {
            try writePreview(rows: previews, to: URL(fileURLWithPath: path))
        }
    }

    func testIdleIconMatchesOriginalNativeRenderingAcrossModesAndAfterStopping() throws {
        _ = NSApplication.shared
        let controller = StatusMenuController(applicationStatusImageURL: originalApplicationImageURL)
        var snapshot = makeSnapshot(state: .idle, isCapturing: false)
        controller.configureRecordingDisplay { snapshot }
        controller.install()
        defer { controller.uninstall() }
        let button = try XCTUnwrap(controller.statusItem?.button)

        // Reproduce the original application's direct resource loading and
        // native image-only rendering, rather than a separately redrawn icon.
        let referenceItem = NSStatusBar.system.statusItem(withLength: StatusMenuController.statusItemWidth)
        defer { NSStatusBar.system.removeStatusItem(referenceItem) }
        referenceItem.menu = NSMenu()
        let reference = try XCTUnwrap(referenceItem.button)
        let original = try XCTUnwrap(NSImage(contentsOfFile: originalApplicationImageURL.path))
        original.size = NSSize(width: 18, height: 18)
        original.isTemplate = true
        reference.title = ""
        reference.image = original
        reference.imageScaling = .scaleProportionallyDown
        reference.imagePosition = .imageOnly

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            button.appearance = appearance
            reference.appearance = appearance
            let expected = try XCTUnwrap(renderButton(reference).tiffRepresentation)
            for mode in MenuBarDisplayMode.allCases {
                controller.update(menuBarDisplayMode: mode)
                for state in [SessionState.idle, .connecting, .recovering, .stopping] {
                    snapshot = makeSnapshot(state: state, isCapturing: false)
                    controller.update(recordingState: state)
                    XCTAssertEqual(button.image?.size, original.size)
                    XCTAssertEqual(button.image?.tiffRepresentation, original.tiffRepresentation)
                    XCTAssertEqual(renderButton(button).tiffRepresentation, expected,
                                   "未录音和停止后必须与原版图标的实际绘制结果一致")
                }
            }
        }
    }

    private var originalApplicationImageURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/brand-kit-graphite/statusbar-matched.png")
    }

    private var states: [SessionState] { [.idle, .connecting, .listening, .recovering, .stopping, .error("failure")] }

    private func makeSnapshot(
        state: SessionState = .listening, isCapturing: Bool = true,
        duration: Double = 61, rms: Double = 0.05
    ) -> RecordingDisplaySnapshot {
        RecordingDisplaySnapshot(
            sessionID: UUID(), state: state,
            audio: AudioCaptureMetricsSnapshot(
                durationSeconds: duration, latestRMS: rms, sampleSequence: 1,
                latestLevelAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                latestLevelDurationSeconds: 0.02
            ),
            isCapturing: isCapturing
        )
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    }

    private func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.6 && color.greenComponent < color.redComponent * 0.75
            && color.blueComponent < color.redComponent * 0.75
    }

    private func visiblePixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5 }.count
        }
    }

    private func redPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.alphaComponent > 0.5 && isRed(color)
            }.count
        }
    }

    private func pixelBounds(_ bitmap: NSBitmapImageRep, matching: (NSColor) -> Bool) throws -> NSRect {
        var points: [NSPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.alphaComponent > 0.5, matching(color) { points.append(NSPoint(x: x, y: y)) }
            }
        }
        let minX = try XCTUnwrap(points.map(\.x).min()), maxX = try XCTUnwrap(points.map(\.x).max())
        let minY = try XCTUnwrap(points.map(\.y).min()), maxY = try XCTUnwrap(points.map(\.y).max())
        return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func renderButton(_ button: NSStatusBarButton) -> NSImage {
        // Let AppKit establish the view's flipped coordinates and appearance.
        // Drawing its cell into an unrelated image context inverts artwork.
        button.layoutSubtreeIfNeeded()
        guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
            XCTFail("无法取得状态栏控件图像")
            return NSImage(size: button.bounds.size)
        }
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let image = NSImage(size: button.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func writePreview(rows: [[NSImage]], to url: URL) throws {
        let image = NSImage(size: NSSize(width: 660, height: 316))
        image.lockFocus()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        ("Rime Voice · 未录音 / 录音中" as NSString).draw(
            at: NSPoint(x: 28, y: 270),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.black]
        )
        for (column, label) in ["录音图标", "累计秒数", "音量波形"].enumerated() {
            (label as NSString).draw(at: NSPoint(x: 214 + column * 150, y: 227),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
        }
        for (row, items) in rows.enumerated() {
            let y = CGFloat(177 - row * 46)
            let dark = row >= 2
            (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white).setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: y - 5, width: 612, height: 38), xRadius: 9, yRadius: 9).fill()
            let label = (dark ? "深色" : "浅色") + " · " + (row % 2 == 0 ? "未录音" : "录音中")
            (label as NSString).draw(at: NSPoint(x: 40, y: y + 5),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dark ? NSColor.lightGray : .darkGray])
            for (column, item) in items.enumerated() {
                item.draw(in: NSRect(x: 214 + column * 150, y: Int(y), width: 56, height: 24))
            }
        }
        image.unlockFocus()
        let bitmap = try self.bitmap(image)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}
