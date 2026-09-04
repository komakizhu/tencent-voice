# 腾讯语音输入 MVP

这是一个只面向当前这台 macOS 的独立试用版：点击一次全局快捷键开始录音，再点击一次停止，腾讯实时语音识别结果会尽量实时改写到当前文本输入框。停止后会继续等待最多 3 秒，让最后一个语音片段完成修正；这段时间不会重新上屏整段文字。当前版本不连接 Rime、Ollama 或任何词库，先用于体验腾讯 ASR 一周。

## 使用

1. 在腾讯云开通实时语音识别，准备 AppID、SecretId、SecretKey。
2. 运行 `./scripts/build-app.sh`。
3. 打开 `dist/TencentVoiceMVP.app`。
4. 首次运行授予麦克风和辅助功能权限；如果系统弹出键盘事件权限提示，请允许腾讯语音输入 MVP。之后在菜单栏“设置…”中保存腾讯凭证。
5. 默认点击 F5 开始录音，再点击 F5 停止；设置中可以重新录制快捷键。

音频只在使用期间发送到腾讯云。应用默认不保存音频，也不保存文本日志；打开“保存文本日志”后，只写入本机 `~/Library/Application Support/TencentVoiceMVP/sessions/` 下的 JSONL 状态记录，不写入 SecretKey、签名 URL 或音频。

当前主要保证常见 Cocoa 文本控件的实时改写。AX 实时模式只替换识别结果发生变化的片段，不会每次重写整个输入框；对不支持“选中文本可写”的控件，会退回到向目标应用发送原生 Unicode 键盘事件：每个语音段只追加一次，同一语音段的后续结果只改写该段自己的临时文字，不使用剪贴板传输实时文字。如果 ASR 结果异常跳变，应用停止发送退格并只追加一次新结果，避免误删或反复复制前文；只有键盘事件失败时才将最终结果放入剪贴板。

## 构建

需要 macOS、Swift 5.10+ 和 Xcode Command Line Tools：

```bash
swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/TencentVoiceMVP.app
```

这是个人本地 MVP，没有 Windows 兼容目标；GitHub Actions 只用于 macOS 测试、构建和版本发布。

## 隐私与凭证

凭证优先保存在 `~/Library/Application Support/TencentVoiceMVP/tencent-credentials.yaml`，文件权限为当前用户可读写（0600），这样启动、录音和用量查询都不会访问钥匙串。只有在 YAML 尚不存在时，打开“设置…”才会尝试从旧 Keychain 迁移一次并写入 YAML；YAML 是明文文件，请勿同步到云盘或提交到 Git。

状态栏菜单会显示当前引擎的本地用量和已用百分比。普通模型按每月免费额度计算；如果使用预付费模型，可在“设置…”中为当前模型选择已充值的总时长（例如 60 小时），应用会跨月份累计该模型的本地用量并计算套餐百分比。应用只在本机记录实际处于“录音中”的时间，每秒刷新一次，停止录音或正常退出时落盘；不会调用腾讯云用量接口，也不会上传用量数据。异常退出时只按最后一次本地心跳恢复，避免把软件未运行的时间算进去。

构建脚本默认使用本机的 `OneKeyIFlyVoice Local Code Signing v4` 签名证书，避免每次重建后 macOS 把应用识别成新的程序。CI 使用 `CODESIGN_IDENTITY=-` 进行临时 ad hoc 签名；也可以通过 `CODESIGN_IDENTITY` 环境变量指定其他已安装的签名证书。

## GitHub Actions

推送到发布分支或提交 Pull Request 会运行 macOS 测试和构建检查。推送形如 `v0.0.1-macos` 的版本标签后，Actions 会在测试和构建成功后自动创建 GitHub Release，并附上 `TencentVoiceMVP-0.0.1-macos.zip`。
