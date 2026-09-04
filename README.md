# 腾讯语音输入 MVP

这是一个只面向当前这台 macOS 的独立试用版：点击一次全局快捷键开始录音，再点击一次停止，腾讯实时语音识别结果会尽量实时改写到当前文本输入框。停止后会继续等待最多 3 秒，让最后一个语音片段完成修正；这段时间不会重新上屏整段文字。腾讯 ASR 会话与 Rime 词库管理是两个独立模块，Rime 管理只负责快照审核和受控词库同步，不改变 ASR 数据管路。

## 使用

1. 在腾讯云开通实时语音识别，准备 AppID、SecretId、SecretKey。
2. 运行 `./scripts/build-app.sh`。
3. 打开 `dist/TencentVoiceMVP.app`。
4. 首次运行后，在菜单栏“设置…”的“系统权限”区域点击“检查权限”。缺少权限时，点击对应项目旁的“打开设置”，按中文用途说明在当前 macOS 账户中开启麦克风、辅助功能、发送键盘事件和输入监控，回来再点击“检查权限”。之后在设置中保存腾讯凭证。
5. 默认点击 Command+0 开始录音，再点击 Command+0 停止；设置中可以重新录制快捷键。

设置页的“测试连接”按钮会使用当前填写的 AppID、SecretId、SecretKey 和识别引擎执行一次腾讯 ASR WebSocket 握手。握手成功才会提示连接可用；这个测试不会录音、不会写入文本，也不会计入用量。

音频只在使用期间发送到腾讯云。应用默认不保存音频，也不保存文本日志；打开“保存文本日志”后，只写入本机 `~/Library/Application Support/TencentVoiceMVP/sessions/` 下的 JSONL 状态记录，不写入 SecretKey、签名 URL 或音频。

当前主要保证常见 Cocoa 文本控件的实时改写。AX 实时模式只替换识别结果发生变化的片段，不会每次重写整个输入框；对不支持“选中文本可写”的控件，会退回到向目标应用发送原生 Unicode 键盘事件：每个语音段只追加一次，同一语音段的后续结果只改写该段自己的临时文字，不使用剪贴板传输实时文字。如果 ASR 结果异常跳变，应用停止发送退格并只追加一次新结果，避免误删或反复复制前文；只有键盘事件失败时才将最终结果放入剪贴板。

## 构建

需要 macOS、Swift 5.10+ 和 Xcode Command Line Tools：

```bash
swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/TencentVoiceMVP.app
```

这是个人本地 MVP，没有 Windows 兼容目标，也没有自动上传或发布流程。

## Rime 双账户迁移与同步

本仓库同时包含仅面向 macOS 的 `RimeSync` Swift 命令行工具，以及 TencentVoiceMVP 菜单栏中的“Rime 词库管理”。命令行工具负责稳定配置的双向同步；菜单栏模块负责生成 `rime_ice` 快照、逐条审核、手动添加和维护独立的 `rime_managed.dict.yaml`，不会调用绕过审核的原生远端合并。使用方式、备份、冲突暂停和回滚说明见 [docs/rime/rime-sync.md](docs/rime/rime-sync.md)。

凭证现在保存在 `/Users/Shared/TencentVoiceMVP/tencent-credentials.yaml`，共享目录归 macOS 的 `staff` 组管理，文件权限为组内账户可读写（0660），因此把应用放在 `/Applications` 后，两个 macOS 用户只要填写的是同一组 AppID、SecretId、SecretKey，就会自动读到同一份凭证。首次读取凭证或打开“设置…”时，会把当前用户旧的 `~/Library/Application Support/TencentVoiceMVP/tencent-credentials.yaml` 或旧 Keychain 凭证迁移到共享文件；共享 YAML 是明文文件，属于同一 `staff` 组的本机账户都可能读取，请勿同步到云盘或提交到 Git。

状态栏菜单会显示共享本机本月用量、当前引擎对应的免费额度参考值和已用百分比。用量账本保存在 `/Users/Shared/TencentVoiceMVP/usage.json`，按 AppID、SecretId、SecretKey 的 SHA-256 指纹和识别引擎分别统计，所以两个账户使用同一密钥时会看到同一累计时长，换密钥后则会分开统计；设置页中的“已充值时长”也按同一凭证共享，方便直接看剩余量。账本不保存 SecretKey 明文；应用只记录实际处于“录音中”的时间，每秒刷新一次，停止录音或正常退出时落盘；不会调用腾讯云用量接口，也不会上传用量数据。旧版本的当前用户用量会在首次识别到对应凭证时迁移一次，异常退出时会回收遗留会话。

构建脚本默认使用本机的 `OneKeyIFlyVoice Local Code Signing v4` 签名证书，避免每次重建后 macOS 把应用识别成新的程序。也可以通过 `CODESIGN_IDENTITY` 环境变量指定其他已安装的签名证书。
