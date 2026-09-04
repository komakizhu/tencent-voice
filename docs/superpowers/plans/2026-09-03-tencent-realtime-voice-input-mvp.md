# 腾讯实时语音输入 MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个仅供当前 macOS 用户使用的独立菜单栏语音输入应用，用可替换的全局快捷键（默认 F5）按住说话，并把腾讯实时 ASR 的临时结果直接改写到当前文本输入位置。

**Architecture:** 使用原生 Swift/AppKit 菜单栏应用，将快捷键、音频、腾讯 WebSocket、ASR 结果归并、辅助功能文本写入和设置存储拆成独立组件。`SessionCoordinator` 只负责一次按键会话的编排；腾讯协议和 macOS AX 细节分别封装在适配器内，核心文本投影可用假对象测试。

**Tech Stack:** Swift 6.1.2、Swift Package Manager、macOS 15+、AppKit、AVFoundation、ApplicationServices、Carbon、Security、Foundation `URLSessionWebSocketTask`、XCTest；不引入第三方运行时依赖。

## Global Constraints

- 平台：仅 macOS；当前机器为 arm64 macOS 15.7，部署目标为 macOS 15.0。
- 快捷键：默认无修饰 `F5`；设置中可替换为功能键或带 `⌘`、`⌥`、`⌃`、`⇧` 的组合键；交互为按住开始、松开结束。
- 文本：没有预编辑窗口、浮层或候选界面；临时识别结果直接改写当前文本控件。
- ASR：使用腾讯实时语音识别 WebSocket，默认 `engine_model_type=16k_zh_en_2.0`、16 kHz 单声道 16-bit PCM、`voice_format=1`、`needvad=0`。
- 音频：按腾讯实时接口建议发送约 200 ms 音频分片，即 16 kHz PCM 每片 6400 字节；结束时发送 `{"type":"end"}`。
- 安全：AppID、SecretId、SecretKey 进入 macOS Keychain；日志中不得出现密钥、签名 URL 或音频。
- 隐私：不保存音频；文本日志开关默认关闭，只在用户打开后写入本机。
- 本次不做：鼠须管/Rime、Ollama/Qwen、词库学习、词频调整、网络热词、腾讯热词/自学习模型、Windows、语音命令。
- 验证：每个核心组件先写 XCTest，再实现最小行为；真实腾讯调用只作为人工集成验收，不写入自动化测试凭证。

---

## 文件结构

先建立下面的目录；每个源文件只承担一个职责：

```text
Package.swift
Resources/Info.plist
Sources/TencentVoiceMVP/
  App/main.swift
  App/AppDelegate.swift
  Core/ASRTypes.swift
  Core/ASRResultNormalizer.swift
  Core/ASRProjectionAccumulator.swift
  Core/PCMChunker.swift
  Tencent/TencentCredentials.swift
  Tencent/TencentSigner.swift
  Tencent/TencentWireMessage.swift
  Tencent/TencentASRClient.swift
  Audio/AudioCapture.swift
  Hotkey/Shortcut.swift
  Hotkey/CarbonHotkeyManager.swift
  Storage/KeychainCredentialStore.swift
  Storage/AppSettings.swift
  Storage/UserDefaultsSettingsStore.swift
  Storage/SessionLogger.swift
  Input/TextTarget.swift
  Input/AXTextTarget.swift
  Input/TextInjector.swift
  Session/SessionCoordinator.swift
  UI/StatusMenuController.swift
  UI/SettingsWindowController.swift
Tests/TencentVoiceMVPTests/
  AppSmokeTests.swift
  ASRResultNormalizerTests.swift
  ASRProjectionAccumulatorTests.swift
  PCMChunkerTests.swift
  TencentSignerTests.swift
  TencentWireMessageTests.swift
  ShortcutTests.swift
  SettingsStoreTests.swift
  TextInjectorTests.swift
  TestDoubles.swift
  SessionCoordinatorTests.swift
  BuildConfigurationTests.swift
scripts/build-app.sh
README.md
```

## Task 1: 建立可运行的 macOS 菜单栏包

**Files:**
- Create: `Package.swift`
- Create: `Sources/TencentVoiceMVP/App/main.swift`
- Create: `Sources/TencentVoiceMVP/App/AppDelegate.swift`
- Create: `Sources/TencentVoiceMVP/UI/StatusMenuController.swift`
- Create: `Resources/Info.plist`
- Create: `Tests/TencentVoiceMVPTests/AppSmokeTests.swift`
- Create: `scripts/build-app.sh`

**Interfaces:**
- Produces executable product `TencentVoiceMVP`.
- `AppDelegate` exposes `statusMenuController` so later tasks可以注入会话状态。
- `StatusMenuController` initially提供“空闲”“退出”两个菜单项；后续任务在同一文件扩展菜单。

- [ ] **Step 1: 写失败的包启动测试**

```swift
import XCTest
@testable import TencentVoiceMVP

final class AppSmokeTests: XCTestCase {
    func testStatusMenuControllerStartsIdle() {
        let controller = StatusMenuController()
        XCTAssertEqual(controller.statusText, "空闲")
    }
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter AppSmokeTests/testStatusMenuControllerStartsIdle`  
Expected: FAIL，因为 `Package.swift`、`StatusMenuController` 和测试目标尚不存在。

- [ ] **Step 3: 写入最小包和菜单栏启动代码**

`Package.swift`：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TencentVoiceMVP",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TencentVoiceMVP", targets: ["TencentVoiceMVP"])
    ],
    targets: [
        .executableTarget(
            name: "TencentVoiceMVP",
            path: "Sources/TencentVoiceMVP"
        ),
        .testTarget(
            name: "TencentVoiceMVPTests",
            dependencies: ["TencentVoiceMVP"],
            path: "Tests/TencentVoiceMVPTests"
        )
    ]
)
```

`Sources/TencentVoiceMVP/App/main.swift`：

```swift
import AppKit

@main
@MainActor
struct TencentVoiceMVPMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
```

`Sources/TencentVoiceMVP/App/AppDelegate.swift`：

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusMenuController: StatusMenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenuController = StatusMenuController()
        statusMenuController.install()
    }
}
```

`Sources/TencentVoiceMVP/UI/StatusMenuController.swift`：

```swift
import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenu = NSMenu()
    private(set) var statusText = "空闲"

    func install() {
        statusItem.button?.title = "🎙"
        let stateItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        statusMenu.addItem(stateItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusMenu.items.last?.target = self
        statusItem.menu = statusMenu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
```

`Resources/Info.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Tencent Voice MVP</string>
    <key>CFBundleExecutable</key>
    <string>TencentVoiceMVP</string>
    <key>CFBundleIdentifier</key>
    <string>local.tencent.voice.mvp</string>
    <key>CFBundleName</key>
    <string>TencentVoiceMVP</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>腾讯语音输入需要访问麦克风来进行实时识别。</string>
</dict>
</plist>
```

`scripts/build-app.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="TencentVoiceMVP"
APP_DIR="$ROOT_DIR/dist/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --product "$PRODUCT_NAME"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/arm64-apple-macosx/release/$PRODUCT_NAME" "$CONTENTS_DIR/MacOS/$PRODUCT_NAME"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
echo "Built $APP_DIR"
```

- [ ] **Step 4: 运行包测试和构建**

Run: `swift test`  
Expected: PASS，至少包含 `AppSmokeTests`。

Run: `swift build -c debug`  
Expected: `Build complete!`。

- [ ] **Step 5: 提交启动骨架**

```bash
git add Package.swift Resources/Info.plist Sources/TencentVoiceMVP Tests/TencentVoiceMVPTests/AppSmokeTests.swift scripts/build-app.sh
git commit -m "chore: bootstrap macOS voice menu bar app"
```

## Task 2: 实现 ASR 事件归并和文本投影核心

**Files:**
- Create: `Sources/TencentVoiceMVP/Core/ASRTypes.swift`
- Create: `Sources/TencentVoiceMVP/Core/ASRResultNormalizer.swift`
- Create: `Sources/TencentVoiceMVP/Core/ASRProjectionAccumulator.swift`
- Create: `Tests/TencentVoiceMVPTests/ASRResultNormalizerTests.swift`
- Create: `Tests/TencentVoiceMVPTests/ASRProjectionAccumulatorTests.swift`

**Interfaces:**
- `ProviderSentence(sequence:sliceType:text:)`：供应商结果的最小表示。
- `ASRUpdate`：`.partial(sequence:text:)`、`.final(sequence:text:)`、`.streamEnded`。
- `ASRResultNormalizer.accept(_:) -> ASRUpdate?`：重复或过期结果返回 `nil`。
- `ASRProjectionAccumulator.apply(_:) -> String?`：返回当前会话应该显示的完整临时文本；无变化返回 `nil`。

- [ ] **Step 1: 写失败测试覆盖临时结果替换、final 去重和多句 final**

```swift
import XCTest
@testable import TencentVoiceMVP

final class ASRResultNormalizerTests: XCTestCase {
    func testPartialThenFinalForSameSequence() {
        let normalizer = ASRResultNormalizer()
        XCTAssertEqual(
            normalizer.accept(ProviderSentence(sequence: 0, sliceType: 1, text: "你好")),
            .partial(sequence: 0, text: "你好")
        )
        XCTAssertEqual(
            normalizer.accept(ProviderSentence(sequence: 0, sliceType: 2, text: "你好世界")),
            .final(sequence: 0, text: "你好世界")
        )
        XCTAssertNil(normalizer.accept(ProviderSentence(sequence: 0, sliceType: 2, text: "你好世界")))
    }

    func testEmptyStartSliceIsIgnored() {
        let normalizer = ASRResultNormalizer()
        XCTAssertNil(normalizer.accept(ProviderSentence(sequence: 0, sliceType: 0, text: "")))
    }
}

final class ASRProjectionAccumulatorTests: XCTestCase {
    func testPartialIsReplacedAndFinalBecomesCommitted() {
        var accumulator = ASRProjectionAccumulator()
        XCTAssertEqual(accumulator.apply(.partial(sequence: 0, text: "你")), "你")
        XCTAssertEqual(accumulator.apply(.partial(sequence: 0, text: "你好")), "你好")
        XCTAssertEqual(accumulator.apply(.final(sequence: 0, text: "你好呀")), "你好呀")
        XCTAssertNil(accumulator.apply(.final(sequence: 0, text: "你好呀")))
    }

    func testMultipleFinalSentencesAreConcatenatedWithoutSyntheticSpaces() {
        var accumulator = ASRProjectionAccumulator()
        XCTAssertEqual(accumulator.apply(.final(sequence: 0, text: "第一句。")), "第一句。")
        XCTAssertEqual(accumulator.apply(.final(sequence: 1, text: "第二句。")), "第一句。第二句。")
    }
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter ASRResultNormalizerTests`  
Expected: FAIL，因为类型和方法尚不存在。

- [ ] **Step 3: 实现核心类型和归并逻辑**

`ASRTypes.swift`：

```swift
public struct ProviderSentence: Equatable, Sendable {
    public let sequence: Int
    public let sliceType: Int
    public let text: String

    public init(sequence: Int, sliceType: Int, text: String) {
        self.sequence = sequence
        self.sliceType = sliceType
        self.text = text
    }
}

public enum ASRUpdate: Equatable, Sendable {
    case partial(sequence: Int, text: String)
    case final(sequence: Int, text: String)
    case streamEnded
}
```

`ASRResultNormalizer.swift`：

```swift
public final class ASRResultNormalizer: @unchecked Sendable {
    private var finalizedSequences = Set<Int>()
    public init() {}

    public func accept(_ sentence: ProviderSentence) -> ASRUpdate? {
        guard sentence.sequence >= 0 else { return nil }
        guard !finalizedSequences.contains(sentence.sequence) else { return nil }

        switch sentence.sliceType {
        case 0, 1:
            guard !sentence.text.isEmpty else { return nil }
            return .partial(sequence: sentence.sequence, text: sentence.text)
        case 2:
            finalizedSequences.insert(sentence.sequence)
            activeSequences.remove(sentence.sequence)
            return .final(sequence: sentence.sequence, text: sentence.text)
        default:
            return nil
        }
    }

    public func acceptStreamEnd() -> ASRUpdate {
        .streamEnded
    }
}
```

`ASRProjectionAccumulator.swift`：

```swift
public struct ASRProjectionAccumulator: Equatable, Sendable {
    private var committed: [Int: String] = [:]
    private var partials: [Int: String] = [:]
    private var lastRendered = ""

    public init() {}

    public mutating func apply(_ update: ASRUpdate) -> String? {
        switch update {
        case let .partial(sequence, text):
            partials[sequence] = text
        case let .final(sequence, text):
            committed[sequence] = text
            partials.removeValue(forKey: sequence)
        case .streamEnded:
            return nil
        }

        let committedText = committed.keys.sorted().compactMap { committed[$0] }.joined()
        let partialText = partials.keys.sorted().compactMap { partials[$0] }.joined()
        let rendered = committedText + partialText
        guard rendered != lastRendered else { return nil }
        lastRendered = rendered
        return rendered
    }
}
```

- [ ] **Step 4: 运行核心测试确认通过**

Run: `swift test --filter ASRResultNormalizerTests`  
Expected: PASS。

Run: `swift test --filter ASRProjectionAccumulatorTests`  
Expected: PASS。

- [ ] **Step 5: 提交核心逻辑**

```bash
git add Sources/TencentVoiceMVP/Core Tests/TencentVoiceMVPTests/ASRResultNormalizerTests.swift Tests/TencentVoiceMVPTests/ASRProjectionAccumulatorTests.swift
git commit -m "feat: normalize realtime ASR results"
```

## Task 3: 接入腾讯签名、WebSocket 和消息解码

**Files:**
- Create: `Sources/TencentVoiceMVP/Tencent/TencentCredentials.swift`
- Create: `Sources/TencentVoiceMVP/Tencent/TencentSigner.swift`
- Create: `Sources/TencentVoiceMVP/Tencent/TencentWireMessage.swift`
- Create: `Sources/TencentVoiceMVP/Tencent/TencentASRClient.swift`
- Create: `Tests/TencentVoiceMVPTests/TencentSignerTests.swift`
- Create: `Tests/TencentVoiceMVPTests/TencentWireMessageTests.swift`

**Interfaces:**
- `TencentSessionConfiguration`：包含 AppID、SecretId、SecretKey、引擎和音频参数。
- `TencentSigner.makeURL(configuration:timestamp:expired:nonce:) throws -> URL`：按官方规则生成签名 URL。
- `RealtimeASRClient.start(configuration:) async throws -> AsyncThrowingStream<ASRUpdate, Error>`。
- `RealtimeASRClient.sendAudio(_:) async throws`、`finish() async throws`、`cancel()`。

- [ ] **Step 1: 写签名和返回 JSON 的失败测试**

```swift
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentSignerTests: XCTestCase {
    func testHMACSHA1UsesRFC2202Vector() throws {
        let key = Data(repeating: 0x0b, count: 20)
        let digest = TencentSigner.hmacSHA1Base64(message: Data("Hi There".utf8), key: key)
        XCTAssertEqual(digest, "thcxhlUFcmTii8C2+zeMjvFGvgA=")
    }

    func testSignedURLContainsPercentEncodedSignatureAndNoSecretKey() throws {
        let configuration = TencentSessionConfiguration(
            appID: "1250000000",
            secretID: "secret-id",
            secretKey: "secret-key",
            engineModelType: "16k_zh_en_2.0",
            voiceID: "voice-1"
        )
        let url = try TencentSigner.makeURL(
            configuration: configuration,
            timestamp: 1_700_000_000,
            expired: 1_700_000_600,
            nonce: 123
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertTrue(url.absoluteString.contains("signature="))
        XCTAssertFalse(url.absoluteString.contains("secret-key"))
    }
}
```

The HMAC assertion uses the fixed RFC 2202 test vector: a 20-byte `0x0b` key and the message `Hi There` must produce the stated Base64 value.

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter TencentSignerTests`  
Expected: FAIL，因为签名器和配置类型尚不存在。

- [ ] **Step 3: 写入凭证、签名和线协议类型**

`TencentCredentials.swift`：

```swift
import Foundation

public struct TencentCredentials: Equatable, Sendable {
    public let appID: String
    public let secretID: String
    public let secretKey: String

    public init(appID: String, secretID: String, secretKey: String) {
        self.appID = appID
        self.secretID = secretID
        self.secretKey = secretKey
    }
}

public struct TencentSessionConfiguration: Equatable, Sendable {
    public let appID: String
    public let secretID: String
    public let secretKey: String
    public let engineModelType: String
    public let voiceID: String
    public let voiceFormat: Int
    public let needVAD: Int

    public init(
        appID: String,
        secretID: String,
        secretKey: String,
        engineModelType: String = "16k_zh_en_2.0",
        voiceID: String = UUID().uuidString,
        voiceFormat: Int = 1,
        needVAD: Int = 0
    ) {
        self.appID = appID
        self.secretID = secretID
        self.secretKey = secretKey
        self.engineModelType = engineModelType
        self.voiceID = voiceID
        self.voiceFormat = voiceFormat
        self.needVAD = needVAD
    }
}

protocol CredentialStore: AnyObject {
    func load() throws -> TencentCredentials?
    func save(_ credentials: TencentCredentials) throws
    func delete() throws
}

enum TencentASRError: Error {
    case invalidURL
    case server(code: Int, message: String)
    case notStarted
    case alreadyFinished
}
```

`TencentSigner.swift` 的签名核心：

```swift
import CryptoKit
import Foundation

enum TencentSigner {
    static func hmacSHA1Base64(message: Data, key: Data) -> String {
        let symmetricKey = SymmetricKey(data: key)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey)
        return Data(digest).base64EncodedString()
    }

    static func makeURL(
        configuration: TencentSessionConfiguration,
        timestamp: Int,
        expired: Int,
        nonce: Int
    ) throws -> URL {
        let hostPath = "asr.cloud.tencent.com/asr/v2/\(configuration.appID)"
        let pairs: [(String, String)] = [
            ("engine_model_type", configuration.engineModelType),
            ("expired", String(expired)),
            ("needvad", String(configuration.needVAD)),
            ("nonce", String(nonce)),
            ("secretid", configuration.secretID),
            ("timestamp", String(timestamp)),
            ("voice_format", String(configuration.voiceFormat)),
            ("voice_id", configuration.voiceID)
        ].sorted { $0.0 < $1.0 }

        let canonicalQuery = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let source = "\(hostPath)?\(canonicalQuery)"
        let signature = hmacSHA1Base64(
            message: Data(source.utf8),
            key: Data(configuration.secretKey.utf8)
        )
        let finalQuery = pairs
            .map { "\($0.0)=\($0.1.percentEncodedForQuery)" }
            .joined(separator: "&")
            + "&signature=\(signature.percentEncodedForQuery)"

        guard let url = URL(string: "wss://\(hostPath)?\(finalQuery)") else {
            throw TencentASRError.invalidURL
        }
        return url
    }
}

private extension String {
    var percentEncodedForQuery: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
```

`TencentWireMessage.swift` 解码标准实时接口的 `result`：

```swift
import Foundation

struct TencentWireResponse: Decodable {
    let code: Int
    let message: String
    let isFinal: Int?
    let result: TencentWireResult?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case isFinal = "final"
        case result
    }
}

struct TencentWireResult: Decodable {
    let sliceType: Int
    let index: Int
    let voiceText: String

    enum CodingKeys: String, CodingKey {
        case sliceType = "slice_type"
        case index
        case voiceText = "voice_text_str"
    }
}
```

- [ ] **Step 4: 写线协议解码和 WebSocket 客户端的最小实现**

线协议测试固定使用腾讯文档中的字段形状：

```swift
import Foundation
@testable import TencentVoiceMVP

final class TencentWireMessageTests: XCTestCase {
    func testDecodePartialResult() throws {
        let data = Data("""
        {"code":0,"message":"success","result":{"slice_type":1,"index":0,"voice_text_str":"实时"}}
        """.utf8)
        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
        XCTAssertEqual(response.result?.sliceType, 1)
        XCTAssertEqual(response.result?.index, 0)
        XCTAssertEqual(response.result?.voiceText, "实时")
    }

    func testDecodeStreamEnd() throws {
        let data = Data(#"{"code":0,"message":"success","final":1}"#.utf8)
        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
        XCTAssertEqual(response.isFinal, 1)
        XCTAssertNil(response.result)
    }
}
```

`TencentASRClient` 必须满足以下精确行为：

```swift
protocol RealtimeASRClient: AnyObject {
    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error>
    func sendAudio(_ data: Data) async throws
    func finish() async throws
    func cancel()
}
```

实现 `start` 时建立 `URLSessionWebSocketTask`，握手响应 `code != 0` 立刻抛出包含 code 的错误；`receive` 循环把 `slice_type` 交给 `ASRResultNormalizer`；顶层 `final == 1` 发出 `.streamEnded` 后结束流。`sendAudio` 只发送 binary message；`finish` 只发送一次 text message `{"type":"end"}`。每次 `start` 都使用配置中的新 UUID voice ID，连接关闭后禁止复用。

- [ ] **Step 5: 运行腾讯协议单元测试**

Run: `swift test --filter TencentSignerTests`  
Expected: PASS。

Run: `swift test --filter TencentWireMessageTests`  
Expected: PASS。

- [ ] **Step 6: 提交腾讯适配器**

```bash
git add Sources/TencentVoiceMVP/Tencent Tests/TencentVoiceMVPTests/TencentSignerTests.swift Tests/TencentVoiceMVPTests/TencentWireMessageTests.swift
git commit -m "feat: add Tencent realtime ASR client"
```

## Task 4: 实现 16 kHz PCM 音频采集和分片

**Files:**
- Create: `Sources/TencentVoiceMVP/Core/PCMChunker.swift`
- Create: `Sources/TencentVoiceMVP/Audio/AudioCapture.swift`
- Create: `Tests/TencentVoiceMVPTests/PCMChunkerTests.swift`

**Interfaces:**
- `PCMChunker.append(_:) -> [Data]`：每 6400 字节输出一个 200 ms 分片。
- `PCMChunker.flush() -> Data?`：会话结束时输出不足一片的剩余数据。
- `AudioCapture.start(onChunk:) async throws`、`stop()`。

- [ ] **Step 1: 写分片器失败测试**

```swift
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class PCMChunkerTests: XCTestCase {
    func testSplits16kMonoPCMInto6400ByteChunks() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        let chunks = chunker.append(Data(repeating: 1, count: 12_800))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count == 6_400 })
        XCTAssertNil(chunker.flush())
    }

    func testFlushReturnsRemainder() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        _ = chunker.append(Data(repeating: 1, count: 100))
        XCTAssertEqual(chunker.flush()?.count, 100)
        XCTAssertNil(chunker.flush())
    }
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter PCMChunkerTests`  
Expected: FAIL，因为 `PCMChunker` 尚不存在。

- [ ] **Step 3: 实现纯分片器**

```swift
import Foundation

public struct PCMChunker: Sendable {
    private let chunkByteCount: Int
    private var buffer = Data()

    public init(chunkByteCount: Int = 6_400) {
        precondition(chunkByteCount > 0)
        self.chunkByteCount = chunkByteCount
    }

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var chunks: [Data] = []
        while buffer.count >= chunkByteCount {
            chunks.append(buffer.prefix(chunkByteCount))
            buffer.removeFirst(chunkByteCount)
        }
        return chunks
    }

    public mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let remainder = buffer
        buffer.removeAll(keepingCapacity: true)
        return remainder
    }
}
```

- [ ] **Step 4: 实现系统采集器**

`AudioCapture` 使用 `AVAudioEngine.inputNode.installTap`，把输入转换成 `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)`；采样率不是 16 kHz 时使用 `AVAudioConverter`。转换后的 `AVAudioPCMBuffer` 通过 `PCMChunker` 输出 Data，所有回调都在音频队列异步执行。`stop()` 必须移除 tap、停止 engine，并 flush 一次剩余分片。

```swift
import AVFoundation
import Foundation

protocol AudioCapture: AnyObject {
    func start(onChunk: @escaping @Sendable (Data) -> Void) async throws
    func stop()
}

enum AudioCaptureError: Error {
    case inputUnavailable
    case converterUnavailable
}
```

- [ ] **Step 5: 运行纯音频测试和构建**

Run: `swift test --filter PCMChunkerTests`  
Expected: PASS。

Run: `swift build`  
Expected: `Build complete!`；没有真实麦克风的自动化测试。

- [ ] **Step 6: 提交音频模块**

```bash
git add Sources/TencentVoiceMVP/Core/PCMChunker.swift Sources/TencentVoiceMVP/Audio/AudioCapture.swift Tests/TencentVoiceMVPTests/PCMChunkerTests.swift
git commit -m "feat: capture and chunk microphone PCM"
```

## Task 5: 实现默认 F5 和可替换全局快捷键

**Files:**
- Create: `Sources/TencentVoiceMVP/Hotkey/Shortcut.swift`
- Create: `Sources/TencentVoiceMVP/Hotkey/CarbonHotkeyManager.swift`
- Create: `Tests/TencentVoiceMVPTests/ShortcutTests.swift`

**Interfaces:**
- `Shortcut(keyCode:modifiers:)` 为 `Codable`、`Equatable`。
- `Shortcut.defaultF5` 为 `UInt32(kVK_F5)` 和 modifiers `0`。
- `CarbonHotkeyManager.register(_:onPress:onRelease:) throws`、`unregister()`。
- 普通字符裸键不通过校验；功能键和至少一个修饰键的组合通过校验。

- [ ] **Step 1: 写快捷键失败测试**

```swift
import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class ShortcutTests: XCTestCase {
    func testDefaultShortcutIsF5WithoutModifiers() {
        XCTAssertEqual(Shortcut.defaultF5, Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0))
    }

    func testShortcutRoundTripsThroughJSON() throws {
        let shortcut = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey))
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), shortcut)
    }

    func testBareLetterIsRejectedButModifiedLetterIsAccepted() {
        XCTAssertFalse(ShortcutValidator.isAllowed(Shortcut(keyCode: 0, modifiers: 0)))
        XCTAssertTrue(ShortcutValidator.isAllowed(Shortcut(keyCode: 0, modifiers: UInt32(optionKey))))
        XCTAssertTrue(ShortcutValidator.isAllowed(Shortcut.defaultF5))
    }
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter ShortcutTests`  
Expected: FAIL，因为快捷键类型尚不存在。

- [ ] **Step 3: 实现配置类型和校验**

```swift
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultF5 = Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
}

enum ShortcutValidator {
    static func isAllowed(_ shortcut: Shortcut) -> Bool {
        let isFunctionKey = (UInt32(kVK_F1)...UInt32(kVK_F20)).contains(shortcut.keyCode)
        let hasModifier = shortcut.modifiers != 0
        return isFunctionKey || hasModifier
    }
}
```

- [ ] **Step 4: 实现 Carbon 按下/松开监听**

使用 `RegisterEventHotKey` 注册 `Shortcut.keyCode` 和 `Shortcut.modifiers`；事件处理器只识别 `kEventHotKeyPressed` 和 `kEventHotKeyReleased`，用 `EventHotKeyRef` 区分当前注册项，忽略重复的 pressed 事件。重新绑定的顺序固定为：先尝试注册新组合，成功后注销旧组合；失败时保留旧组合并抛出 `hotkeyUnavailable`。

```swift
protocol HotkeyManaging: AnyObject {
    func register(
        _ shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) throws
    func unregister()
}

enum HotkeyError: Error {
    case invalidShortcut
    case hotkeyUnavailable(OSStatus)
}
```

- [ ] **Step 5: 运行快捷键测试和构建**

Run: `swift test --filter ShortcutTests`  
Expected: PASS。

Run: `swift build`  
Expected: `Build complete!`。

- [ ] **Step 6: 提交快捷键模块**

```bash
git add Sources/TencentVoiceMVP/Hotkey Tests/TencentVoiceMVPTests/ShortcutTests.swift
git commit -m "feat: add configurable global hotkey"
```

## Task 6: 实现 Keychain 凭证、设置存储和设置窗口

**Files:**
- Create: `Sources/TencentVoiceMVP/Storage/KeychainCredentialStore.swift`
- Create: `Sources/TencentVoiceMVP/Storage/AppSettings.swift`
- Create: `Sources/TencentVoiceMVP/Storage/UserDefaultsSettingsStore.swift`
- Create: `Sources/TencentVoiceMVP/UI/SettingsWindowController.swift`
- Create: `Tests/TencentVoiceMVPTests/SettingsStoreTests.swift`

**Interfaces:**
- `TencentCredentials(appID:secretID:secretKey:)` 为 `Sendable`、`Equatable`。
- `CredentialStore.load() throws -> TencentCredentials?`、`save(_:) throws`、`delete() throws`。
- `AppSettings` 默认 shortcut 为 `Shortcut.defaultF5`、引擎为 `16k_zh_en_2.0`、`saveTextLogs=false`。
- `SettingsStore.load() -> AppSettings`、`save(_:)`。

- [ ] **Step 1: 写 UserDefaults 失败测试**

```swift
import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class SettingsStoreTests: XCTestCase {
    func testDefaultsUseF5AndDisableTextLogs() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = store.load()
        XCTAssertEqual(settings.shortcut, .defaultF5)
        XCTAssertEqual(settings.engineModelType, "16k_zh_en_2.0")
        XCTAssertFalse(settings.saveTextLogs)
    }

    func testSettingsRoundTrip() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = AppSettings(
            shortcut: Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey)),
            engineModelType: "16k_zh_en_2.0",
            saveTextLogs: true
        )
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter SettingsStoreTests`  
Expected: FAIL，因为设置类型和存储器尚不存在。

- [ ] **Step 3: 实现设置类型和 UserDefaults 存储**

```swift
protocol SettingsStore: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

struct AppSettings: Codable, Equatable, Sendable {
    var shortcut: Shortcut = .defaultF5
    var engineModelType = "16k_zh_en_2.0"
    var saveTextLogs = false
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "appSettings"

    init(suiteName: String = "local.tencent.voice.mvp") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: 实现 Keychain 存储**

使用 `Security` 的 `SecItemCopyMatching`、`SecItemAdd`、`SecItemUpdate`；service 固定为 `local.tencent.voice.mvp.credentials`，account 分别为 `appID`、`secretID`、`secretKey`。读取不到项目时返回 `nil`；任何 Keychain 错误转换为 `CredentialStoreError.status(OSStatus)`，错误描述只包含状态码，不包含查询字典值。

```swift
import Security

enum CredentialStoreError: Error {
    case status(OSStatus)
}

final class KeychainCredentialStore: CredentialStore {
    private let service = "local.tencent.voice.mvp.credentials"

    func load() throws -> TencentCredentials? {
        let appID = try read(account: "appID")
        let secretID = try read(account: "secretID")
        let secretKey = try read(account: "secretKey")
        guard let appID, let secretID, let secretKey else { return nil }
        return TencentCredentials(appID: appID, secretID: secretID, secretKey: secretKey)
    }

    func save(_ credentials: TencentCredentials) throws {
        try write(credentials.appID, account: "appID")
        try write(credentials.secretID, account: "secretID")
        try write(credentials.secretKey, account: "secretKey")
    }

    func delete() throws {
        for account in ["appID", "secretID", "secretKey"] {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.status(status)
            }
        }
    }

    private func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.status(errSecDecode)
        }
        return value
    }

    private func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.status(updateStatus)
        }
    }
}
```

- [ ] **Step 5: 实现设置窗口**

使用 AppKit 原生 `NSWindowController` 和 Auto Layout，窗口包含：AppID 普通输入框、SecretId 普通输入框、SecretKey `NSSecureTextField`、当前快捷键显示/重新录制按钮、识别引擎输入框、保存文本日志复选框、保存按钮和状态说明。快捷键录制只保存允许的组合；保存新快捷键时先调用 `HotkeyManaging.register`，成功后再写入 UserDefaults。窗口关闭不清空已经保存的凭证。

```swift
import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let appIDField = NSTextField()
    private let secretIDField = NSTextField()
    private let secretKeyField = NSSecureTextField()
    private let engineField = NSTextField()
    private let logCheckbox = NSButton(checkboxWithTitle: "保存文本日志", target: nil, action: nil)
    private let onSave: (AppSettings, TencentCredentials) -> Void

    init(settings: AppSettings, credentials: TencentCredentials?, onSave: @escaping (AppSettings, TencentCredentials) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tencent Voice MVP 设置"
        self.onSave = onSave
        super.init(window: window)
        appIDField.stringValue = credentials?.appID ?? ""
        secretIDField.stringValue = credentials?.secretID ?? ""
        secretKeyField.stringValue = credentials?.secretKey ?? ""
        engineField.stringValue = settings.engineModelType
        logCheckbox.state = settings.saveTextLogs ? .on : .off
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildView() {
        let content = NSStackView(views: [appIDField, secretIDField, secretKeyField, engineField, logCheckbox])
        content.orientation = .vertical
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = NSView()
        window?.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 24)
        ])
        appIDField.placeholderString = "AppID"
        secretIDField.placeholderString = "SecretId"
        secretKeyField.placeholderString = "SecretKey"
        engineField.placeholderString = "引擎，例如 16k_zh_en_2.0"
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveButtonPressed))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 16)
        ])
    }

    @objc private func saveButtonPressed(_ sender: NSButton) {
        let credentials = TencentCredentials(appID: appIDField.stringValue, secretID: secretIDField.stringValue, secretKey: secretKeyField.stringValue)
        let settings = AppSettings(engineModelType: engineField.stringValue, saveTextLogs: logCheckbox.state == .on)
        onSave(settings, credentials)
    }
}
```

- [ ] **Step 6: 运行设置测试**

Run: `swift test --filter SettingsStoreTests`  
Expected: PASS。

Run: `swift build`  
Expected: `Build complete!`。

- [ ] **Step 7: 提交设置模块**

```bash
git add Sources/TencentVoiceMVP/Storage Sources/TencentVoiceMVP/UI/SettingsWindowController.swift Tests/TencentVoiceMVPTests/SettingsStoreTests.swift
git commit -m "feat: store credentials securely and configure app"
```

## Task 7: 实现辅助功能文本目标和安全实时替换

**Files:**
- Create: `Sources/TencentVoiceMVP/Input/TextTarget.swift`
- Create: `Sources/TencentVoiceMVP/Input/AXTextTarget.swift`
- Create: `Sources/TencentVoiceMVP/Input/TextInjector.swift`
- Create: `Tests/TencentVoiceMVPTests/TextInjectorTests.swift`
- Create: `Tests/TencentVoiceMVPTests/TestDoubles.swift`

**Interfaces:**
- `TextTarget.capture() throws -> TextSnapshot`：读取焦点控件、完整文本和 UTF-16 选区。
- `TextTarget.replace(snapshot:range:expectedText:with:) throws -> TextRange`：只在目标和预期文本仍匹配时改写。
- `TextInjector.begin()` 选择 `.live` 或 `.finalPaste`。
- `TextInjector.apply(renderedText:)` 只替换当前会话拥有的范围。
- `TextInjector.finish(renderedText:)` 在 live 模式最终替换一次；无法安全写入时只复制最终文本，不盲目追加。

- [ ] **Step 1: 写假文本目标失败测试**

```swift
import XCTest
@testable import TencentVoiceMVP

final class TextInjectorTests: XCTestCase {
    func testPartialUpdatesReplaceOwnedRange() throws {
        let target = FakeTextTarget(text: "前缀")
        let injector = TextInjector(target: target)
        try injector.begin()
        try injector.apply(renderedText: "你")
        try injector.apply(renderedText: "你好")
        try injector.finish(renderedText: "你好呀")
        XCTAssertEqual(target.text, "前缀你好呀")
        XCTAssertEqual(target.replaceCallCount, 3)
    }

    func testExternalEditStopsLiveReplacementAndCopiesFinal() throws {
        let target = FakeTextTarget(text: "原文")
        let injector = TextInjector(target: target)
        try injector.begin()
        try injector.apply(renderedText: "临时")
        target.text = "用户自己改过的文字"
        try injector.finish(renderedText: "最终")
        XCTAssertEqual(target.text, "用户自己改过的文字")
        XCTAssertEqual(target.copiedText, "最终")
    }
}
```

`Tests/TencentVoiceMVPTests/TestDoubles.swift`：

```swift
import Foundation
@testable import TencentVoiceMVP

final class FakeTextTarget: TextTarget {
    var text: String
    private(set) var copiedText: String?
    private(set) var replaceCallCount = 0

    init(text: String) {
        self.text = text
    }

    func capture() throws -> TextSnapshot {
        TextSnapshot(text: text, selection: TextRange(location: text.utf16.count, length: 0))
    }

    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with replacement: String) throws -> TextRange {
        guard text == expectedText else { throw TextTargetError.targetChanged }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        text = mutable as String
        replaceCallCount += 1
        return TextRange(location: range.location, length: replacement.utf16.count)
    }

    func paste(_ text: String) throws {
        copiedText = text
    }
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter TextInjectorTests`  
Expected: FAIL，因为文本目标和注入器尚不存在。

- [ ] **Step 3: 实现纯文本范围和注入状态**

```swift
import Foundation

struct TextRange: Equatable, Sendable {
    var location: Int
    var length: Int
}

struct TextSnapshot {
    let text: String
    let selection: TextRange
}

protocol TextTarget: AnyObject {
    func capture() throws -> TextSnapshot
    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with text: String) throws -> TextRange
    func paste(_ text: String) throws
}

enum TextTargetError: Error {
    case unsupported
    case targetChanged
    case writeFailed
}
```

`TextInjector` 的状态规则固定为：`begin` 保存快照并把 owned range 初始化为原选择区；第一次 `apply` 将原选择区替换为结果；后续 `apply` 以 `lastRenderedText` 为 expectedText 替换 owned range；任何 `targetChanged`/`unsupported` 都切换到安全模式；`finish` 在安全模式只执行一次 `paste`，paste 失败则保留文本到内存状态并显示错误。

`TextInjector.swift` 的最小状态实现：

```swift
final class TextInjector {
    private enum Mode: Equatable { case inactive, live, finalPaste, safeCopy }

    private let target: TextTarget
    private var snapshot: TextSnapshot?
    private var ownedRange = TextRange(location: 0, length: 0)
    private var lastRenderedText = ""
    private var mode: Mode = .inactive

    init(target: TextTarget) {
        self.target = target
    }

    func begin() throws {
        do {
            let captured = try target.capture()
            snapshot = captured
            ownedRange = captured.selection
            lastRenderedText = captured.text
            mode = .live
        } catch TextTargetError.unsupported {
            snapshot = nil
            lastRenderedText = ""
            mode = .finalPaste
        }
    }

    func apply(renderedText: String) throws {
        guard mode == .live, let snapshot else { return }
        guard renderedText != lastRenderedText else { return }
        do {
            ownedRange = try target.replace(
                snapshot: snapshot,
                range: ownedRange,
                expectedText: lastRenderedText,
                with: renderedText
            )
            lastRenderedText = renderedText
        } catch TextTargetError.targetChanged, TextTargetError.unsupported, TextTargetError.writeFailed {
            mode = .safeCopy
        }
    }

    func finish(renderedText: String) throws {
        defer {
            snapshot = nil
            mode = .inactive
            lastRenderedText = ""
        }
        switch mode {
        case .live:
            try apply(renderedText: renderedText)
            if mode == .safeCopy { try target.paste(renderedText) }
        case .finalPaste, .safeCopy:
            try target.paste(renderedText)
        case .inactive:
            break
        }
    }
}
```

- [ ] **Step 4: 实现 AXTextTarget**

使用 `AXUIElementCreateSystemWide` 获取 `kAXFocusedUIElementAttribute`，读取 `kAXValueAttribute` 和 `kAXSelectedTextRangeAttribute`。`AXValueGetValue` 以 `CFRange` 取 UTF-16 位置；写入时用 `NSMutableString.replaceCharacters(in:with:)` 保留用户其余文本，然后通过 `AXUIElementSetAttributeValue` 设置新值，再设置新的 `kAXSelectedTextRangeAttribute`。设置前验证：焦点元素对象仍相同、当前 AXValue 等于 `expectedText`、当前选区位置等于 owned range 的末端。

如果缺少 AXValue 或 AXSelectedTextRange，`capture` 抛出 `.unsupported`，注入器使用最终粘贴模式。剪贴板回退使用 `NSPasteboard.general` 写入最终文本并通过 `CGEvent` 发送 `⌘V`；若辅助功能权限不足导致 CGEvent 失败，只保留剪贴板内容并报告状态。

- [ ] **Step 5: 运行注入器单元测试**

Run: `swift test --filter TextInjectorTests`  
Expected: PASS。

- [ ] **Step 6: 提交文本注入模块**

```bash
git add Sources/TencentVoiceMVP/Input Tests/TencentVoiceMVPTests/TextInjectorTests.swift Tests/TencentVoiceMVPTests/TestDoubles.swift
git commit -m "feat: replace live ASR text safely"
```

## Task 8: 编排一次 F5 会话并接入菜单栏状态

**Files:**
- Create: `Sources/TencentVoiceMVP/Session/SessionCoordinator.swift`
- Modify: `Sources/TencentVoiceMVP/App/AppDelegate.swift`
- Modify: `Sources/TencentVoiceMVP/UI/StatusMenuController.swift`
- Create: `Tests/TencentVoiceMVPTests/SessionCoordinatorTests.swift`
- Create: `Sources/TencentVoiceMVP/Storage/SessionLogger.swift`

**Interfaces:**
- `SessionCoordinator` 为 `@MainActor` 对象，公开 `begin()`、`end()`、`cancel()`、`state`。
- 依赖注入 `HotkeyManaging`、`AudioCapture`、`RealtimeASRClient`、`TextTarget`、`SettingsStore`、`CredentialStore` 和状态回调；测试不访问真实麦克风、AX 或网络。
- 状态枚举：`.idle`、`.connecting`、`.listening`、`.stopping`、`.error(String)`。

- [ ] **Step 1: 写会话编排失败测试**

```swift
import Foundation
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testPartialThenFinalIsWrittenWithoutDuplication() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let target = FakeTextTarget(text: "")
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)

        try await coordinator.begin()
        await asr.emit(.partial(sequence: 0, text: "你"))
        await asr.emit(.partial(sequence: 0, text: "你好"))
        await asr.emit(.final(sequence: 0, text: "你好呀"))
        try await coordinator.end()

        XCTAssertEqual(target.text, "你好呀")
        XCTAssertEqual(target.text.components(separatedBy: "你好呀").count - 1, 1)
    }

    func testCredentialFailureDoesNotTouchTarget() async throws {
        let target = FakeTextTarget(text: "原文")
        let coordinator = makeCoordinator(credentials: nil, target: target)
        await assertThrowsAsync { try await coordinator.begin() }
        XCTAssertEqual(target.text, "原文")
    }
}
```

`SessionCoordinatorTests.swift` 同时提供测试替身和工厂，避免触碰真实网络、麦克风或 AX：

```swift
final class FakeRealtimeASRClient: RealtimeASRClient {
    private var continuation: AsyncThrowingStream<ASRUpdate, Error>.Continuation!
    private lazy var stream = AsyncThrowingStream<ASRUpdate, Error> { continuation in
        self.continuation = continuation
    }
    private(set) var finishCallCount = 0

    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error> {
        stream
    }

    func sendAudio(_ data: Data) async throws {}

    func finish() async throws {
        finishCallCount += 1
        continuation.yield(.streamEnded)
        continuation.finish()
    }

    func cancel() {
        continuation.finish()
    }

    func emit(_ update: ASRUpdate) {
        continuation.yield(update)
    }
}

final class FakeAudioCapture: AudioCapture {
    private var handler: (@Sendable (Data) -> Void)?
    private(set) var startCallCount = 0

    func start(onChunk: @escaping @Sendable (Data) -> Void) async throws {
        handler = onChunk
        startCallCount += 1
    }

    func stop() {}
    func emit(_ data: Data) { handler?(data) }
}

final class InMemoryCredentialStore: CredentialStore {
    var credentials: TencentCredentials?

    init(_ credentials: TencentCredentials?) {
        self.credentials = credentials
    }

    func load() throws -> TencentCredentials? { credentials }
    func save(_ credentials: TencentCredentials) throws { self.credentials = credentials }
    func delete() throws { credentials = nil }
}

func assertThrowsAsync<T>(_ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected an error")
    } catch {
        // Expected path.
    }
}

@MainActor
func makeCoordinator(
    asr: RealtimeASRClient = FakeRealtimeASRClient(),
    audio: AudioCapture = FakeAudioCapture(),
    target: TextTarget,
    credentials: TencentCredentials? = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
) -> SessionCoordinator {
    SessionCoordinator(
        asr: asr,
        audio: audio,
        textTarget: target,
        settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
        credentialStore: InMemoryCredentialStore(credentials),
        onStateChange: { _ in }
    )
}
```

- [ ] **Step 2: 运行测试确认当前失败**

Run: `swift test --filter SessionCoordinatorTests`  
Expected: FAIL，因为编排器和 fake 依赖尚不存在。

- [ ] **Step 3: 实现连接前 1 秒音频缓冲**

增加一个 actor `AudioPrebuffer`：最多保存 5 个 200 ms 的 PCM 回调，即不超过 1 秒；ASR 连接成功后按原顺序转发并清空；连接失败、取消或会话结束时清空。音频回调不可阻塞音频线程，统一使用 `Task { try? await prebuffer.append(chunk) }`。

```swift
actor AudioPrebuffer {
    private let maxChunkCount = 5
    private var pending: [Data] = []
    private var sink: (@Sendable (Data) async throws -> Void)?

    func append(_ data: Data) async throws {
        if let sink {
            try await sink(data)
            return
        }
        pending.append(data)
        if pending.count > maxChunkCount { pending.removeFirst() }
    }

    func attach(_ sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        self.sink = sink
        let buffered = pending
        pending.removeAll(keepingCapacity: true)
        for chunk in buffered { try await sink(chunk) }
    }

    func clear() {
        pending.removeAll(keepingCapacity: true)
        sink = nil
    }
}
```

- [ ] **Step 4: 实现 SessionCoordinator 状态机**

`SessionCoordinator` 的构造器和公开状态边界如下；初始化时保存所有依赖，不能在类内部创建真实的网络、麦克风或 AX 单例：

```swift
enum SessionState: Equatable {
    case idle
    case connecting
    case listening
    case stopping
    case error(String)
}

enum SessionError: Error {
    case credentialsMissing
    case microphoneDenied
    case noTextTarget
}

@MainActor
protocol SessionCoordinating: AnyObject {
    var state: SessionState { get }
    func begin() async throws
    func end() async throws
    func cancel()
}
```

实现 `begin()` 时必须依次完成：读取凭证、检查麦克风授权、创建 `TextInjector` 并捕获目标、创建新 `voiceID`、启动 `AudioPrebuffer`、启动 ASR、把 prebuffer 连接到 `sendAudio`、消费 ASR stream。实现 `end()` 时必须停止音频、只调用一次 `finish()`、等待最多 2 秒的事件流、调用 `TextInjector.finish` 一次并回到 idle。所有状态变化都调用 `onStateChange`；状态机不允许从 error 直接开始下一次会话，必须先回到 idle。

`begin()` 按顺序执行：检查当前状态为 idle；检查 Keychain 凭证；检查麦克风权限；捕获文本目标；创建新 `voiceID` 配置；启动音频并写入 prebuffer；启动 ASR；ASR 握手成功后排空 prebuffer 并进入 listening；启动独立事件任务。

事件任务收到 `.partial`/`.final` 后交给 `ASRProjectionAccumulator`，只有返回非 nil 的新投影才调用 `TextInjector.apply`。收到 `.streamEnded` 只更新结束标志，不再次写入。

`end()` 必须幂等：第一次调用停止音频、调用 `RealtimeASRClient.finish()`、进入 stopping；最多等待 2 秒的事件流结束；若已有安全投影则调用 `TextInjector.finish` 一次；取消事件任务、清空 prebuffer、回到 idle。重复调用不发送第二个 end、不追加文本。

AX 目标变化时，`TextInjector` 进入安全模式；ASR 仍可继续到 `end()`，最终文本只复制到剪贴板。任何 ASR 错误都停止继续写入、设置 error 状态，并在菜单栏展示可读错误。

- [ ] **Step 5: 实现本地文本日志**

仅当 `AppSettings.saveTextLogs == true` 时写入 `~/Library/Application Support/TencentVoiceMVP/sessions/YYYY-MM-DD.jsonl`。每行只包含时间、会话 ID、事件类型、文本、延迟和错误码；不得包含音频、SecretId、SecretKey、签名 URL。目录不存在时使用 `FileManager.createDirectory` 创建；日志写入失败不影响输入会话，只更新菜单栏错误状态。

`SessionLogger.swift` 的边界：

```swift
import Foundation

struct SessionLogEntry: Encodable, Sendable {
    let timestamp: Date
    let sessionID: UUID
    let event: String
    let text: String?
    let latencyMilliseconds: Int?
    let errorCode: Int?
}

final class SessionLogger {
    private let enabled: () -> Bool
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled
    }

    func append(_ entry: SessionLogEntry) throws {
        guard enabled() else { return }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let fileURL = directory.appendingPathComponent("\(formatter.string(from: entry.timestamp)).jsonl")
        var line = try encoder.encode(entry)
        line.append(0x0A)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }
}
```

- [ ] **Step 6: 接入状态菜单和快捷键回调**

AppDelegate 创建真实依赖：`UserDefaultsSettingsStore`、`KeychainCredentialStore`、`CarbonHotkeyManager`、`SystemAudioCapture`、`TencentASRClient`、`AXTextTarget`、`StatusMenuController` 和 `SessionCoordinator`。注册当前设置中的 shortcut；press 调 `begin()`，release 调 `end()`。菜单栏状态必须显示 idle/connecting/listening/stopping/error，并提供“停止”“设置…”和“退出”。

- [ ] **Step 7: 运行编排测试**

Run: `swift test --filter SessionCoordinatorTests`  
Expected: PASS。

Run: `swift test`  
Expected: 所有单元测试 PASS。

- [ ] **Step 8: 提交会话编排**

```bash
git add Sources/TencentVoiceMVP/Session Sources/TencentVoiceMVP/Storage/SessionLogger.swift Sources/TencentVoiceMVP/App/AppDelegate.swift Sources/TencentVoiceMVP/UI/StatusMenuController.swift Tests/TencentVoiceMVPTests/SessionCoordinatorTests.swift
git commit -m "feat: orchestrate push to talk voice sessions"
```

## Task 9: 打包、说明和一周人工验收

**Files:**
- Modify: `scripts/build-app.sh`
- Create: `README.md`
- Create: `Tests/TencentVoiceMVPTests/BuildConfigurationTests.swift`

**Interfaces:**
- `scripts/build-app.sh` 输出 `dist/TencentVoiceMVP.app` 并完成 ad-hoc 签名。
- README 必须明确凭证、权限、快捷键和云端音频传输说明。

- [ ] **Step 1: 写构建配置失败测试**

```swift
import XCTest
@testable import TencentVoiceMVP

final class BuildConfigurationTests: XCTestCase {
    func testDefaultModelAndShortcutAreTheMVPDefaults() {
        XCTAssertEqual(AppSettings().engineModelType, "16k_zh_en_2.0")
        XCTAssertEqual(AppSettings().shortcut, .defaultF5)
        XCTAssertFalse(AppSettings().saveTextLogs)
    }
}
```

- [ ] **Step 2: 运行完整测试确认通过**

Run: `swift test`  
Expected: PASS，因为前面任务已经提供 AppSettings 和默认快捷键。

- [ ] **Step 3: 完成构建脚本和 README**

README 必须包含以下可直接执行的流程：

```text
1. 在腾讯云开通实时语音识别并准备 AppID、SecretId、SecretKey。
2. 运行 ./scripts/build-app.sh。
3. 打开 dist/TencentVoiceMVP.app。
4. 首次运行授予麦克风和辅助功能权限，在设置中保存腾讯凭证。
5. 默认按住 F5 说话，松开结束；在设置中可以改快捷键。
6. 音频会在使用期间发送到腾讯云；应用默认不保存音频和文本日志。
```

README 还要列出：当前只保证常见 Cocoa 文本控件实时改写；不支持 AX 的控件会采用最终粘贴；用户在说话期间手动改字或切换窗口时，应用会停止覆盖并把最终结果放入剪贴板；本版本不连接 Rime、Ollama 或任何词库。

- [ ] **Step 4: 运行打包验证**

Run: `bash -n scripts/build-app.sh`  
Expected: 无输出、退出码 0。

Run: `swift test`  
Expected: 所有自动测试 PASS。

Run: `./scripts/build-app.sh`  
Expected: 输出 `Built .../dist/TencentVoiceMVP.app`，且 `test -x dist/TencentVoiceMVP.app/Contents/MacOS/TencentVoiceMVP` 成功。

Run: `codesign --verify --deep --strict dist/TencentVoiceMVP.app`  
Expected: 无错误。

- [ ] **Step 5: 人工验收，不由自动化代替**

在 TextEdit、备忘录、浏览器文本框和常用代码编辑器分别验证：

1. F5 按下后状态从 idle 到 connecting/listening；能看到临时文字变化。
2. 松开 F5 后只保留一次最终文字，没有重复、残留或意外删除前文。
3. 中英文混说、`skill`、`Whisper`、人名和软件名可以正常返回。
4. 在设置中改为 `⌥F5` 或 `⌘⇧Space` 后，F5 不再触发，新组合可以触发。
5. 无麦克风权限、无辅助功能权限、错误凭证、无文本焦点、网络断开和不支持 AX 的控件都有明确状态，已有文本不被覆盖。
6. 打开文本日志后确认只有文本/状态字段；关闭后不再新增日志；任何文件中都找不到 SecretKey 或签名 URL。
7. 连续使用七天，记录延迟、错词、漏词、重复文本和失败会话，作为是否继续做 Rime/Ollama 扩展的依据。

- [ ] **Step 6: 提交可试用版本**

```bash
git add scripts/build-app.sh README.md Tests/TencentVoiceMVPTests/BuildConfigurationTests.swift
git commit -m "docs: package Tencent voice MVP for local trial"
```

## Self-Review Checklist

- 规格覆盖：Task 1 覆盖菜单栏包和权限描述；Task 2 覆盖 partial/final 去重和多句投影；Task 3 覆盖腾讯签名、`voice_id`、WebSocket 二进制音频和 end 消息；Task 4 覆盖 16 kHz PCM 与 6400 字节分片；Task 5 覆盖默认 F5 和可替换 keyDown/keyUp；Task 6 覆盖 Keychain 与设置；Task 7 覆盖 AX 实时改写和安全回退；Task 8 覆盖会话状态、1 秒预缓冲、2 秒结束等待和文本日志；Task 9 覆盖打包与一周验收。
- 占位扫描：计划不使用未决占位标记或模糊的未来决策要求；每个任务都有目标文件、接口、测试命令和提交命令。
- 接口一致性：`ASRUpdate` 由 Task 2 定义，Task 3 和 Task 8 使用；`RealtimeASRClient` 在 Task 3 定义，Task 8 注入；`Shortcut` 在 Task 5 定义，Task 6 和 Task 9 使用；`TextTarget`/`TextInjector` 在 Task 7 定义，Task 8 使用。
- 范围检查：所有任务都服务于一次独立 macOS 腾讯 ASR 试用；Rime、Ollama、词库和热点功能没有进入实现计划。
