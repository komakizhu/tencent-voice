# 腾讯语音输入 MVP

这是一个只面向当前这台 macOS 的独立试用版：点击一次全局快捷键开始录音，再点击一次停止，腾讯实时语音识别结果会尽量实时改写到当前文本输入框。停止后会继续等待最多 3 秒，让最后一个语音片段完成修正；这段时间不会重新上屏整段文字。腾讯 ASR 会话与 Rime 词库管理是两个独立模块，Rime 管理只负责快照审核和受控词库同步，不改变 ASR 数据管路。

## 使用

1. 在腾讯云开通实时语音识别，准备 AppID、SecretId、SecretKey。
2. 运行 `./scripts/install-app.sh`。它会构建并覆盖 `/Applications/TencentVoiceMVP.app`，并通过脚本打开 macOS 隐私设置页面。
3. 在 macOS 系统设置中手动开启麦克风、辅助功能、发送键盘事件和输入监控，再回到菜单栏“设置…”点击“检查权限”。也可以单独运行 `./scripts/request-permissions.sh microphone` 等命令打开指定页面。
4. 之后直接打开 `/Applications/TencentVoiceMVP.app` 即可；普通启动和点击“开始录音”都只检查权限，不会再次主动申请。
5. 默认点击 Command+0 开始录音，再点击 Command+0 停止；设置中可以重新录制快捷键。

当前开发支线版本为 0.2.1，基于 `main` 的 0.2.0 build 45。

设置页的“测试连接”按钮会使用当前填写的 AppID、SecretId、SecretKey 和识别引擎执行一次腾讯 ASR WebSocket 握手。握手成功才会提示连接可用；这个测试不会录音、不会写入文本，也不会计入用量。

设置页的“故障诊断记录”复选框用于录制一次完整复现过程：勾选后开始记录设置快照、快捷键、权限检查、连接测试、会话状态、识别结果长度、写入计数和错误码；再次取消勾选后会自动把机器可读的 JSON 导出到桌面。记录期间会同步保存脱敏的临时 journal；如果应用异常退出，下次启动会自动恢复为桌面 JSON。JSON 不包含 AppID、SecretId、SecretKey、录音、识别文字、输入框原文或剪贴板正文，但会包含当前用户、App/目标应用路径、Bundle ID 和进程号等定位信息，请在分享前确认。

音频只在使用期间发送到腾讯云。应用默认不保存音频，也不保存诊断日志；打开“保存崩溃日志”后，只写入本机 `~/Library/Application Support/TencentVoiceMVP/sessions/` 下的 JSONL 状态记录，不写入 SecretKey、签名 URL 或音频。

当前主要保证常见 Cocoa 文本控件的实时改写。AX 实时模式只替换识别结果发生变化的片段，不会每次重写整个输入框；对不支持“选中文本可写”的控件，会退回到 `keyboard_live_tail`：每个 partial 立即上屏，纯增长只追加，改词时在同一个串行键盘事务中从首个分歧处选中旧尾巴并写入新尾巴，不发送逐字退格，也不会因 final 修订永久停止后续句段。超过 12 个字的修订记为深修订，但仍立即上屏，避免长句再次停更；本地会话日志会记录深修订次数和最大长度。可读取辅助功能光标的目标还会在每次写入前校验焦点元素和光标位置。实时会话开启腾讯 VAD，停顿约 1 秒后由服务端结束当前句段并继续接收下一句。停止时会先发送音频采集队列中最后的分片，再发送结束标记，并最多等待 3 秒接收 final。设置页的“Safe Copy（始终复制到剪贴板）”关闭时，输入错误会停止继续写入但不会自动复制；打开并保存后，所有支持文本输入的应用都直接走 Safe Copy，即使没有发生错误也会在会话结束时复制最终识别结果。

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

权限准备由 `scripts/request-permissions.sh` 负责，应用日常运行和点击“开始录音”都只检查权限，不会触发新的系统权限弹窗。macOS 不允许普通脚本静默授予 TCC 权限，因此脚本负责打开准确的设置页，授权仍需在“系统设置 → 隐私与安全性”中手动完成；已经拒绝的权限不会被应用反复重新申请。
