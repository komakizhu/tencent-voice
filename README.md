# Rime Voice

这是一个只面向当前这台 macOS 的独立试用版：点击一次全局快捷键开始录音，再点击一次停止，腾讯实时语音识别结果会尽量实时改写到当前文本输入框。停止后会继续等待最多 3 秒，让最后一个语音片段完成修正；这段时间不会重新上屏整段文字。腾讯 ASR 会话与 Rime 管理是两个独立模块，Rime 管理提供手动配置存档迁移、本机快照审核和受控词库维护，不改变 ASR 数据管路。

## 使用

麦克风显示“尚未决定”时，点击设置页“麦克风”右侧的“打开设置”，应用会单独发起麦克风授权请求。点击系统弹窗中的“允许”后，状态会自动刷新；若未允许，则打开麦克风系统设置供手动调整。此操作保留其他已有权限，不需要重置全部授权。

1. 在腾讯云开通实时语音识别，准备 AppID、SecretId、SecretKey。
2. 运行 `./scripts/install-app.sh`。它会构建并覆盖 `/Applications/Rime Voice.app`，并通过脚本打开 macOS 隐私设置页面。
3. Rime Voice 保留原“讯飞一键语音”的 Bundle ID `local.onekey.iflyvoice` 和固定签名，因此旧 App 已授予的辅助功能、发送键盘事件和输入监控权限会继续生效。首次使用 Rime Voice 仍需在 macOS 系统设置中单独开启麦克风，因为原 App 不使用麦克风。若仍缺少权限，在菜单栏“设置…”点击对应的“打开设置”即可；只有需要清除共享的旧授权记录时才使用“重置并重新授权”。
4. 之后直接打开 `/Applications/Rime Voice.app` 即可；普通启动和点击“开始录音”都只检查权限，不会再次主动申请。如果点击 F5 或“开始录音”时麦克风仍未授权，应用会自动打开设置并显示具体原因；点击“麦克风”右侧的“打开设置”完成授权后再试。
5. 默认点击 Command+0 开始录音，再点击 Command+0 停止；设置中可以选择 F5（屏蔽 macOS 听写）、Esc、Home、Page Up、Page Down 预设，也可以重新录制快捷键。

当前 `main` 版本为 0.3.2，构建号以 `Resources/Info.plist` 为准，应用界面不显示构建号。

应用对外名称为 Rime Voice；为保持已有系统权限、凭证和日志数据兼容，内部可执行文件、Bundle ID（`local.onekey.iflyvoice`）和历史数据目录仍沿用旧标识。

设置页的“测试连接”按钮会使用当前填写的 AppID、SecretId、SecretKey 和识别引擎执行一次腾讯 ASR WebSocket 握手。握手成功才会提示连接可用；这个测试不会录音、不会写入文本，也不会计入用量。

设置页的“自动保存诊断日志”是唯一的日志开关：勾选后点击“保存设置”生效；关闭时不新增持久化日志，开启后会自动把会话状态、错误代码和操作上下文写入本机 `~/Library/Application Support/TencentVoiceMVP/sessions/` 下的 JSONL 文件。设置页同一行右侧的“导出诊断报告”会打开保存面板，把当前已保存的全部会话与诊断事件、运行环境、权限和诊断判断导出为一个 JSON 文件；不会因为开关变化自动导出到桌面，也不需要单独开始或结束一次“故障诊断记录”。

音频只在使用期间发送到腾讯云。应用默认不保存音频和诊断日志；日志中的文本只用于记录长度、计数和错误类型，不写入 SecretKey、签名 URL、录音、识别文字、输入框原文或剪贴板正文。导出的 JSON 仍会包含当前用户、App/目标应用路径、Bundle ID 和进程号等定位信息，请在分享前确认。

设置页的“保存设置”按钮会同时保存应用设置和腾讯凭证，但保存位置不同：应用设置保存在当前 macOS 账户的应用偏好中，凭证保存在 `/Users/Shared/TencentVoiceMVP/tencent-credentials.yaml`，会话日志不在共享目录。设置页的“数据位置”区域可以直接打开会话日志目录和诊断报告目录；凭证共享目录仍由共享凭证说明管理。

当前主要保证常见 Cocoa 文本控件的实时改写。AX 实时模式只替换识别结果发生变化的片段，不会每次重写整个输入框；对不支持“选中文本可写”的控件，会退回到 `keyboard_live_tail`：每个 partial 立即上屏，纯增长只追加，改词时在同一个串行键盘事务中从首个分歧处选中旧尾巴并写入新尾巴，不发送逐字退格，也不会因 final 修订永久停止后续句段。超过 12 个字的修订记为深修订，但仍立即上屏，避免长句再次停更；本地会话日志会记录深修订次数和最大长度。可读取辅助功能光标的目标还会在每次写入前校验焦点元素和光标位置。实时会话开启腾讯 VAD，停顿约 1 秒后由服务端结束当前句段并继续接收下一句。停止时会先发送音频采集队列中最后的分片，再发送结束标记，并最多等待 3 秒接收 final。设置页的“Safe Copy（始终复制到剪贴板）”开启后，仍按正常路径实时输出到当前输入框，并随识别更新实时备份完整文字到剪贴板，在会话结束时再同步最终结果；如果正常写入发生错误，才会切换到 clipboard-only 的 Safe Copy 回退路径。关闭时，输入错误会停止继续写入且不会自动复制。识别流在未请求停止时结束会停止麦克风并提示错误，避免仍显示录音却不再识别。开启诊断日志后，会每 5 秒及结束时记录采集/上传分片计数、音频时长与识别更新间隔；不保存音频或文字正文。

## 构建

需要 macOS、Swift 5.10+ 和 Xcode Command Line Tools：

```bash
swift test
./scripts/build-app.sh
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
codesign --verify --deep --strict "dist/Rime Voice Build${build_number}.app"
```

修改代码后的测试构建会递增 Build 号，测试产物名称包含 Build 号。提交后的定稿、发布、释放和覆盖不再递增；`TVMVP_BUILD_MODE=keep ./scripts/build-app.sh` 会按已提交的构建号完整编译，并生成 `dist/Rime Voice.app`。安装脚本和 GitHub Actions Release 均采用此模式；设置页、正式发布包内的 App 名称和 `/Applications/Rime Voice.app` 均不显示 Build 号。

这是个人本地 macOS 应用，没有 Windows 兼容目标，也没有自动上传或发布流程。

## Rime 跨账户配置迁移

Rime Voice 提供“导出所有配置…”与“导入所有配置…”两个手动迁移入口。导入前完整校验存档并预览逐文件新增、替换和相同项；确认后备份受影响文件、保留目标账户独有文件，并在失败时回滚。存档可以携带 `custom_phrase.txt`、皮肤、方案、词典、Lua、OpenCC、语法模型和受控长期词库，但不包含 `installation.yaml`、实时 `.userdb`、机器身份或审核历史。流程与回滚说明见 [docs/rime/rime-sync.md](docs/rime/rime-sync.md)。

“Rime 词库管理”保留为本机工具：打开窗口只读取当前账户已有的审核数据；只有明确点击“刷新本机快照”才会先备份本地状态，再将本机 `sync_dir` 设为私有目录并生成快照。审核缓存和备份保存在当前账户的 Application Support；不会调用 Squirrel `--sync` 或读取另一账户快照。旧的自动同步、冲突解决和共享快照脚本已停用，旧共享数据保持不动。

凭证现在保存在 `/Users/Shared/TencentVoiceMVP/tencent-credentials.yaml`，共享目录归 macOS 的 `staff` 组管理，文件权限为组内账户可读写（0660），因此把应用放在 `/Applications` 后，两个 macOS 用户只要填写的是同一组 AppID、SecretId、SecretKey，就会自动读到同一份凭证。首次读取凭证或打开“设置…”时，会把当前用户旧的 `~/Library/Application Support/TencentVoiceMVP/tencent-credentials.yaml` 或旧 Keychain 凭证迁移到共享文件；共享 YAML 是明文文件，属于同一 `staff` 组的本机账户都可能读取，请勿同步到云盘或提交到 Git。

状态栏菜单会显示共享本机本月用量、当前引擎对应的免费额度参考值和已用百分比。用量账本保存在 `/Users/Shared/TencentVoiceMVP/usage.json`，按 AppID、SecretId、SecretKey 的 SHA-256 指纹和识别引擎分别统计，所以两个账户使用同一密钥时会看到同一累计时长，换密钥后则会分开统计；设置页中的“已充值时长”也按同一凭证共享，方便直接看剩余量。账本不保存 SecretKey 明文；应用只记录实际处于“录音中”的时间，每秒刷新一次，停止录音或正常退出时落盘。旧版本的当前用户用量会在首次识别到对应凭证时迁移一次，异常退出时会回收遗留会话。

菜单默认显示本机估算用量，不会自动请求腾讯云。点击唯一的“校准用量…”按钮时，应用使用设置中已有的 SecretId 和 SecretKey 查询当前模型的有效实时识别资源包：标准模型优先核对当月免费额度，免费额度耗尽后使用匹配的付费包；大模型核对各自的付费包。确认使用查询结果后，用量与额度会写入共享账本，重新启动后继续显示，并从校准值累计后续录音。免费额度按月统计，付费包跨月累计。无需登录腾讯云网页。若没有对应资源包、只有后付费用量、查询失败或结果与控制台不符，弹窗可手动输入小时和分钟，或打开[腾讯云资源包页面](https://console.cloud.tencent.com/asr/resourcebundle)核查；浏览器可能要求登录。手动校正保留历史录音记录，后续录音继续累计。腾讯云资源包接口的响应可能变更，失效时可使用页面核对或手动校正。

构建脚本默认使用本机的 `OneKeyIFlyVoice Local Code Signing v4` 签名证书，避免每次重建后 macOS 把应用识别成新的程序。Rime Voice 还固定使用旧 App 的 Bundle ID `local.onekey.iflyvoice`，以便继承“讯飞一键语音”的 TCC 授权。也可以通过 `CODESIGN_IDENTITY` 环境变量指定其他已安装的签名证书。为避免授权失效，本地构建会拒绝 `CODESIGN_IDENTITY=-` 的 ad-hoc 签名；只有 GitHub Actions 等不需要继承本机 TCC 授权的构建，才可以显式设置 `TVMVP_ALLOW_ADHOC_SIGNING=1`。

请使用同一份固定签名的 App：开发安装运行 `./scripts/install-app.sh` 后，从 `/Applications/Rime Voice.app` 启动；不要直接运行旧的 `dist` 副本。macOS 的麦克风、辅助功能、发送键盘事件和输入监控授权属于 Bundle ID 与代码签名身份，重新构建后只有这两者保持一致时才会继承。

权限准备由 `scripts/request-permissions.sh` 负责，应用日常运行和点击“开始录音”都只检查权限，不会触发新的系统权限弹窗。设置页的“重置并重新授权”会调用 macOS `tccutil reset All` 清除 Rime Voice 的旧 TCC 记录，再打开逐步授权向导；向导会按麦克风、辅助功能、发送键盘事件、输入监控逐项引导，回到向导后会校验当前步骤再进入下一步。macOS 不允许普通脚本或密码静默授予 TCC 权限，因此每一项开关仍需用户在系统设置中确认。
