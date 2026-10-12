# 语音输入故障场记

## 当前范围

用户最新指示：在 App 内记录故障前一分钟，重点观察 Codex；并先修复已明确的 Safari ChatGPT 不上屏问题。已实现 Safari ProseMirror 的键盘输入分流与 App 内故障场记。Codex 和微信上屏逻辑保持原样；后续根据用户报告做 RCA。此前每小时的外部检查已暂停。

独立分支：`codex/task-20261010`。工作目录：`/Users/mac2/.codex/worktrees/task-20261010/Rime+腾讯语音+自适应词库`。基线测试 416 个通过；修改后全量测试 423 个通过。Safari 组完整构建 Build113；故障场记组完整构建 Build114；重复报告保存修复后完整构建 Build115，签名验证、Info.plist 校验及可执行文件检查均通过。用户随后要求提交；App 尚未安装替换正在运行的版本。

## App 内使用

运行 `dist/Rime Voice Build115.app`。菜单中先开启“记录 Codex 故障前一分钟操作”（默认关闭，独立保存启用选择）；遇到问题立即点“报告输入失效”，再点“打开失效报告目录”。每次点击都会生成新的 UUID 文件并独立保存，连续点击会保留每一份，不会刷新或覆盖上一次；隐藏状态栏图标时，应用主菜单也有相同入口。报告位于 `~/Library/Application Support/TencentVoiceMVP/input-failure-reports/InputFailure-<UUID>.json`，不会自动上传。

桌面记录为内存滚动缓冲：前台应用变化、点击及坐标、滚动、Codex 已知导航/剪贴板快捷键（包含 Command+Option+N）、不含字符的键盘活动标记。每 500ms 在独立后台队列只读查询 Codex AX 焦点和窗口身份、角色、选择范围、可用时的字符数量；不会读窗口标题或 AXValue，不采集普通打字内容、录音、截图或剪贴板。安全输入启用时不记录键盘活动。关闭记录清空缓冲。

报告包含精确请求的一分钟时间范围、实际启用起点、当前权限/监视器状态、截断计数，以及同一分钟的现有输入诊断事件。输入日志即使没有开启磁盘持久化，也会在启用场记后保留最多 12000 条相关内存事件；桌面缓冲最多 2000 条。截断或未启用记录时会明确标记。500ms AX 采样可能错过更短的焦点变化，权限不足或安全输入会限制可见事件；没有事件不等于操作未发生。

Safari 修复只针对 Safari 内 AXTextArea 且 DOM class 包含 ProseMirror 的编辑器：避开返回成功却未上屏的 AX 文本写入，复用既有键盘输入及回执校验。Safari 原生输入框仍走原 AX 路径。Build115 的真实报告确认该分流已生效（`safariWebEditor=true`、`keyboardCompatibility=true`），但键盘路径在连续输入中仍可能出现 `text_target_changed` 回执失败，详见后续报告；没有自动激活 Safari 或向用户草稿注入测试文本。

## 监控方式

以下外部定期检查方案已暂停，保留供 RCA 检索参考：读取 `/Users/mac2/Library/Application Support/TencentVoiceMVP/sessions/` 的现有 JSONL 日志，按 sessionID 记录故障。日志文件的日期按本机写入规则确定，不能假定文件名日期与 timestamp 的 UTC 日期相同。展示时间一律转换为 Asia/Shanghai，并保留原始 UTC 时间方便定位。

只记录时间、sessionID、eventID、目标应用、sourceBuild、事件顺序、错误码，以及长度、坐标、AX 状态等必要元数据。不得复制识别正文、草稿、剪贴板、密钥或完整原始日志。检查异常时关联同一会话的 capture、dispatch、acknowledgement、degradation、finalization；区分主动切换焦点和程序故障。普通操作导致的 targetChanged 不能自动算作 bug。

无新增可行动证据时保持安静。重复已知错误仅追加场记，不每小时发同样的提醒。仅在用户报告需要 RCA、出现有证据支持的新故障模式、日志不可用影响分析或需要用户操作时报告。监控依赖 Codex 本地调度和现有 App 日志，不是实时系统事件录制器；不会凭会话日志推断具体快捷键。若没有新日志，也不能认定没有故障。

用户报告时建议提供：大致时间、应用、失败前最后一个操作、是没有识别还是识别后未上屏、怎样恢复。报告不完整也先按时间关联现有日志。

## 用户报告

- 2026-10-10：微信和 Codex 大多能输入；Codex 偶发无法上屏，某些操作之后更常见；“关了再打开”后曾恢复，但具体重启对象尚未确认。
- 2026-10-10：`Command+Option+N` 开启支线会话时经常失效；没有确定稳定复现步骤。再次尝试又恢复，因此要求先长期监控。
- 2026-10-10：Safari 的 ChatGPT 聊天输入框语音未上屏。

## 已确认的日志现象

当前已安装 App 日志标记 sourceBuild=112。以下仅确认故障链路，不等于所有根因已确认。

- Safari，2026-10-10 12:40:43–12:40:44（UTC 04:40:43–04:40:44），sessionID `89B247E8-9795-4CD1-8B14-634BD7F4995C`：捕获模式 ax，原文长度 1；此前 AX selected 写入状态 0（success），下一次 ax_document_mismatch 仍读到长度 1，期望长度 3；随后 input_degradation / text_target_changed，进入 safe_copy。当天多个 Safari 会话出现相同链路。
- Codex，2026-10-10 12:41:56–12:41:57（UTC 04:41:56–04:41:57），sessionID `5C509813-6578-4887-A074-9FAA740D400B`：捕获成功、占位文本归一化为空、keyboard_live_tail；随后 keyboard_focus_changed 与 input_degradation / text_target_changed，进入 safe_copy。无法从现有日志证明这次一定由 Command+Option+N 引发。
- Codex，2026-10-10 12:39:49–12:39:51（UTC 04:39:49–04:39:51），sessionID `EE972A77-8F8B-486A-9E41-0E60942E45D7`：input_degradation 的 failureCode 为 KeyboardWriteReadError。需要对齐用户报告并读取该会话必要元数据，不能把所有 Codex 故障都归为焦点变化。

## 只读检查与待验证假设

后台 AX 检查没有激活或切换窗口。Safari 的 ChatGPT 编辑器为 AXTextArea、AXDOMClassList 包含 ProseMirror、AXValue 长度 1。Codex 的焦点一次返回 Conversation 的 AXGroup，另一时刻返回标记 AXFocused=1 的 ProseMirror AXTextArea。是否是同一操作导致、是否外层焦点可安全解析到编辑器，都尚未证明。

Safari 避开 AX 假成功写入的修复已实现。只读确认 Safari 的 AXStringForRange 包含段落换行，因此保留原有普通键盘坐标处理，没有套用 Codex 的换行映射。Codex 可能存在容器焦点/编辑器重建或读取回执异常，尚未改动其输入逻辑。

## 增量检查位置

初始已读至 2026-10-10.jsonl 的 timestamp `2026-10-10T04:47:30.181Z`，eventID `9D666DE9-4798-4D88-9712-01A02FC70C76`。这是日志定位记录，不是完整性或发布校验机制。后续以事件 ID 去重，并注意异步写入可能出现 timestamp 小于上一条记录的新增事件；必要时重叠读取日志尾部，不仅按时间过滤。

## 后续故障记录

由本聊天的定期后台检查或用户报告触发分析后追加。

- 2026-10-10 14:56:22（UTC 06:56:22），报告 `InputFailure-12213862-1612-4A47-AC1F-38B373E57FEA.json`，来源 Build114，已保存在 `~/Library/Application Support/TencentVoiceMVP/input-failure-reports/`，前一份报告仍保留。报告覆盖 14:55:22–14:56:22；桌面场记无丢弃事件，未记录普通输入文字、截图或安全输入内容，但这一分钟只有 5 条桌面事件。
- Safari 会话 `1FEADE0A-E5C9-4B4E-B100-783973EE62D1`（14:55:22.646–14:55:40.512）：105 次输入操作均确认，无失败码。
- Safari 会话 `5D097E95-6F40-43F9-8CCD-3378A22F5124`（14:55:45.813–14:56:15.136）：初始目标识别为 Safari ProseMirror 编辑器，AX 可读可写、键盘兼容；前 22 次操作确认。14:55:51.513（UTC 06:55:51.513）第 23 次操作未确认，失败码 `text_target_write_failed`，随后进入 safe_copy；14:55:51.823 记录 safe_copy。现有报告能确认是写入回执失败，不能仅凭场记确定具体鼠标动作或 DOM 变化原因。
- 2026-10-10 14:57:56（UTC 06:57:56），报告 `InputFailure-6A6D5A97-C151-452B-911C-49C26576B070.json`，来源 Build115，已独立保存在同一目录；当前共 3 份报告，均未覆盖。报告覆盖 14:56:56–14:57:56，桌面场记 21 条、丢弃 0 条；记录到 Finder、Codex 与 Safari 的切换，但 Safari 的 AX 焦点细节仍由输入诊断事件记录。
- Safari 会话 `565CE78A-30D3-401D-A781-8FB7A11F0C31`（14:57:27.926–14:57:50.406）：初始目标为 Safari ProseMirror 编辑器，`safariWebEditor=true`、`keyboardCompatibility=true`，前 23 次操作确认。14:57:35.623（UTC 06:57:35.623）第 24 次操作未确认，失败码 `text_target_changed`，随后进入 safe_copy；这说明 Build115 已进入预期的 Safari 键盘分流，但连续输入期间目标回执仍会失效，尚不能认为 Safari 问题已解决。

## 2026-10-12 Safari 两次停止输入（Build120）

报告按北京时间读取：18:51:28 的 `InputFailure-B111A084-A768-4E08-ABEB-C8AA649FED41.json` 和 18:53:57 的 `InputFailure-9BAA92AD-5FEE-44D8-B3DB-1E0D2B6A10F4.json`。第二份报告未覆盖故障起点，已补查 `sessions/2026-10-12.jsonl`；不把缺失的现场记录当作没有异常。

第一项：会话 `B7D467BF-D94C-44DB-959F-1C4B46C4FF12` 操作 38，18:51:09.532 提交追加，此前 37 次提交；确认阶段先读到不匹配正文，随后 AXValue 返回 `-25202`（kAXErrorFailure）。18:51:09.574 即未确认退出，耗时 42ms、读取 2 次。代码把该读取错误归为终止错误，因此现有 5 秒确认期限未能发挥作用。修复限定 Safari ProseMirror 已捕获目标的 AXValue/AXSelectedTextRange 的该返回码，重新读取直至严格确认或到期；不重新发送，不更改其他应用读取策略。

第二项：会话 `2BF001E6-C074-4512-8569-EF56760D1120` 操作 334，18:52:30.864 提交一个字符，预期全文 UTF16 长度 498、光标 497。此前操作 333 确认全文 497；操作 334 经 380 次读取、5002ms 后仍为 documentMismatch，最后读回全文 500。用户确认只有语音输入，没有手动打字、粘贴或输入法候选操作。现有证据不能区分网页正文/结构变化、输入法影响或额外字符来源；不能归因于用户编辑，也不能忽略额外字符后确认成功。本阶段保留失败停止保护，补记未确认时的预期全文长度和预期/实际选区；此项仍待现场证据，尚未修复。

在 `codex/isolated-app-task` 独立工作树实施。新增回放覆盖 transient AX failure 后持续输入、持续失败到期、限定错误/应用范围、发送前读取恢复，以及 498/500 正文不匹配仍停止。全量 441 项测试通过。不记录正文，不修改日志脱敏规则；不自动提交、合并或安装。
