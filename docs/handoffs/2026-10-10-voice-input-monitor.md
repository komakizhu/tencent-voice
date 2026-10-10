# 语音输入故障场记

## 当前范围

用户最新指示：在 App 内记录故障前一分钟，重点观察 Codex；并先修复已明确的 Safari ChatGPT 不上屏问题。已实现 Safari ProseMirror 的键盘输入分流与 App 内故障场记。Codex 和微信上屏逻辑保持原样；后续根据用户报告做 RCA。此前每小时的外部检查已暂停。

独立分支：`codex/task-20261010`。工作目录：`/Users/mac2/.codex/worktrees/task-20261010/Rime+腾讯语音+自适应词库`。基线测试 416 个通过；修改后全量测试 423 个通过。Safari 组完整构建 Build113；故障场记组完整构建 Build114，签名验证、Info.plist 校验及可执行文件检查均通过。用户随后要求提交；App 尚未安装替换正在运行的版本。

## App 内使用

运行 `dist/Rime Voice Build114.app`。菜单中先开启“记录 Codex 故障前一分钟操作”（默认关闭，独立保存启用选择）；遇到问题立即点“报告输入失效”，再点“打开失效报告目录”。隐藏状态栏图标时，应用主菜单也有相同入口。报告位于 `~/Library/Application Support/TencentVoiceMVP/input-failure-reports/InputFailure-<UUID>.json`，不会自动上传。

桌面记录为内存滚动缓冲：前台应用变化、点击及坐标、滚动、Codex 已知导航/剪贴板快捷键（包含 Command+Option+N）、不含字符的键盘活动标记。每 500ms 在独立后台队列只读查询 Codex AX 焦点和窗口身份、角色、选择范围、可用时的字符数量；不会读窗口标题或 AXValue，不采集普通打字内容、录音、截图或剪贴板。安全输入启用时不记录键盘活动。关闭记录清空缓冲。

报告包含精确请求的一分钟时间范围、实际启用起点、当前权限/监视器状态、截断计数，以及同一分钟的现有输入诊断事件。输入日志即使没有开启磁盘持久化，也会在启用场记后保留最多 12000 条相关内存事件；桌面缓冲最多 2000 条。截断或未启用记录时会明确标记。500ms AX 采样可能错过更短的焦点变化，权限不足或安全输入会限制可见事件；没有事件不等于操作未发生。

Safari 修复只针对 Safari 内 AXTextArea 且 DOM class 包含 ProseMirror 的编辑器：避开返回成功却未上屏的 AX 文本写入，复用既有键盘输入及回执校验。Safari 原生输入框仍走原 AX 路径。真实 Safari 语音验收尚待用户运行新版；没有自动激活 Safari 或向用户草稿注入测试文本。

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
