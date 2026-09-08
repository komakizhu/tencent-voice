# 输入诊断报告增强：交接给另一个会话

## 任务边界与接手口令

用户要求将“诊断报告增强”交给另一个会话，当前会话继续排查 Codex 自动上屏中断。本文件只交接报告、采集和验证要求，不授予提交、合并或发布权限。

可直接发给接手会话：

> 请基于这份交接增强 Rime Voice 原有的会话日志和导出诊断报告。先确认原任务 worktree 中尚未提交的改动，保留原作者工作，在独立分支开展。不要另建诊断入口，不要修改输入策略、等待阈值或焦点保护；这些属于原会话。请补齐操作级诊断关联、平滑路径修订计数、真实等待与未等待的分类，以及本文验收矩阵。所有持久化沿用原日志开关；不记录文本正文、剪贴板、密钥或音频。完整编译 App，提供可运行 App 链接，不自动 commit 或发布。

## 工作区状态

- 原仓库：`/Users/mac2/Documents/ChatGPT/Rime+腾讯语音+自适应词库`
- 当前 worktree：`/Users/mac2/Documents/ChatGPT/Rime+腾讯语音+自适应词库-task`
- 当前分支：`codex/task-20260908-131558-1`
- 创建时基点：`7ff3b68`，当时的 `github/main`。
- 当前最新构建：`dist/Rime Voice.app`，build 66。
- 功能、诊断、测试改动仍未提交。不要假设仅检出该分支或基点就能得到当前修改，也不要直接 cherry-pick 不存在的提交。
- 原仓库还有其他用户改动；不要覆盖。不要让两个会话同时修改同一 worktree。
- build 66 已完整编译、签名验证，83 项相关测试通过；但用户已复现继续中断，不能称为修复验收通过。

## 三组真实证据

所有下述时间为 2026-09-08，北京时间；JSONL 原始时间为 UTC。

### A. AX 报告成功，但后续读回不符

文件：`/Users/mac2/Library/Application Support/TencentVoiceMVP/ax-diagnostic/trace.jsonl`

诊断 session：`0AF17B98-4A70-48F3-B884-E9CDCA523718`，build 63，13:50。

- Codex bundle ID 为 `com.openai.codex`，文本初始 UTF-16 长度 5，光标 0。
- AX 声明 selected/value 均可写；写 selected text 返回 status 0。
- 下一次读回仍为长度 5，预期为 7；焦点比较通过。
- 确认的是写入成功返回与读回状态不一致，不能断言 DOM 重建，也不能区分写入未生效、回滚、反馈滞后和外部编辑。
- build 64 起 Codex 从会话开始使用键盘路径；该输入策略不属于本报告任务。

### B. 光标反馈短暂滞后

文件：`/Users/mac2/Library/Application Support/TencentVoiceMVP/ax-diagnostic/keyboard-trace.jsonl`

诊断 session：`6692F79E-A641-44CB-8BF9-491BC6DB5979`，build 65，14:26:54。

- 距离最后一次本地发送约 29.782ms，预期光标 128/0，实际 127/0。
- 50ms 后实际变为 128/0，应用和元素身份都相同。
- 旧逻辑首次读回不符立即停止；这是可证实的瞬时反馈延迟误判。
- build 66 增加了条件性等待，但不能视作整个输入链路的根治。

### C. final 深修订后出现大选区，下一段中断

文件：`/Users/mac2/Library/Application Support/TencentVoiceMVP/sessions/2026-09-08.jsonl`

ASR session：`1461EB5B-BD7C-4B63-B257-8D0629A46389`，build 66。

| 北京时间 | 事件 | 证据 |
| --- | --- | --- |
| 14:42:16 至 14:42:45 | 6 次 caret recovered | 每次 1 次轮询，等待 10–17ms 后匹配 |
| 14:42:52.208 | segment 0 / revision 87 partial | renderedLength 303，writeCount 296 |
| 14:42:52.954 | segment 0 / revision 88 final | renderedLength 302，writeCount 300 |
| 14:42:53.183 | segment 1 / revision 89 partial | 下一段开始，renderedLength 305 |
| 14:42:53.287 | keyboard_caret_timeout | 预期 302/0，实际 location 199 / length 104 |
| 同上 | 等待信息 | 距最后发送 333.471958ms；polls 0，waitMilliseconds 0 |
| 14:42:54.353 | safe_copy | text_target_changed，writeCount 300 |
| 14:43:11.896 | finished | 最终识别长度 430，写入数仍为 300 |

注意：这不是“150ms 等待之后仍未恢复”。因为超过距上次发送 250ms 的条件，根本没有进入等待。当前事件名 timeout 不准确，必须区分未等待和等待超时。

用户观察到段落整体修订后停止。104 字符选区与尾部修订可能有关，但目前没有 operation ID 和阶段记录，不能证明对应哪次 Shift+Left 操作，也不能断言丢键或焦点重建。

## 当前已做的报告改动（尚未提交）

`Sources/TencentVoiceMVP/TextInputDiagnostic.swift`：增加内存诊断事件模型；同文件还包含输入等待逻辑，接手会话不要整文件覆盖。

`TextTarget.swift` 和 `TextInjector.swift`：增加 drainDiagnostics，将目标层诊断交给会话层。TextInjector 同时含 Codex 输入策略修改，不能全部搬走或回退。

`AXTextTarget.swift`：增加捕获能力字段、光标恢复/失败、AX 读取/写入/读回不符等事件；同文件包含输入等待修复，属于共享修改热点。

`SessionCoordinator.swift`：将诊断事件按 ASR session ID 写入原 SessionLogger，附带 sourceBuild/sourceAppPath；已有正常事件也记录来源。

`DiagnosticReport.swift`：按 session/time 整理，增加各类诊断判断；原 JSON events 和文本 metadata 可携带细节。

`Tests/TencentVoiceMVP/DiagnosticReportTests.swift`：已有统一日志、持久化开关和正文脱敏测试。

独立诊断写盘代码已从当前源码移除；旧诊断 App 和旧证据文件仍保留。旧版独立 trace 的 session ID 不是 ASR session ID，不可直接混用。当前实现不会自动把旧 trace 导入报告。

## 必须补齐的字段和语义

### 操作关联

- ASR session ID、segment ID、revision、partial/final/streamEnd。
- 每次输入操作的 operation ID、类型（append / tail replacement / AX replacement）。
- 用普通递增编号即可，不引入哈希、冻结协议或额外硬门禁。
- 操作创建、排队、开始发送、发送结束、观察反馈、完成/失败的单调时钟时间。
- 故障前后有限数量的操作上下文，说明是否截断及丢弃多少条。
- 记录失败发生时的原模式，不要只记录已经变成 safe_copy 的模式。
- 区分故障发生时间和“下一条 ASR 到来时才记录降级”的报告时间。

### 文本修订结构（不包含正文）

- desired/submitted/observed 各自的长度，并说明当前 observed 能证明的范围。
- 公共前缀长度、旧尾长度、新尾长度、是否跨句段、修订触发类型。
- 同时标明 Character 与 UTF-16 的单位，不能直接相减或拿来解释光标。
- planned selection、实际读回 selection、预期结束光标。
- 平滑路径和即时路径使用一致的计数口径。
- 已确认计数缺口：`applyKeyboardCandidate` 会更新 deepReplacementCount / maximumTrailingReplacementLength，但 `replacePacedTrailingText` 没有更新这些计数。因而目前的 0 不能说明没有深修订。
- writeCount 目前代表调用/提交，不是用户可见文字已确认落入文档；报告不能称之为“成功上屏次数”。

### 键盘阶段

- 发送目标主进程 PID、AX 元素所属 PID、前台应用是否相同、元素是否相同。
- 选择旧尾前、选择完成观察、写入新尾后各自状态。
- 计划和已投递键盘事件数量、Unicode 块数量、Shift 状态，仅数值和枚举。
- 必须把“本地投递完成”和“目标处理完成”分开；postToPid 返回不提供后者证明。
- lastDispatchAge、实际轮询次数、实际等待耗时、等待预算和资格判断原因。
- 分类至少包含：匹配无需等、短暂滞后后匹配、等待超时、未满足等待条件、读取失败、应用变化、元素变化、选区仍非空。
- 不得把 selected range 非空自动判为“用户移动光标”，它也可能是本程序选中旧尾的中间态。

### AX 不上屏

- 捕获时的角色/可读属性/可写属性（不得采集控件标题、描述或输入正文）。
- 具体写入属性、返回码、写入操作编号和时间。
- 写前/写后/下一次读回的长度与匹配布尔值；不保存全文和内容哈希。
- 焦点身份变化、文本不匹配、范围不匹配、接口失败分别分类。
- 单次 final 后没有第二次写入的情形也需要考虑，不能只依赖下一条 partial 才发现读回不符。
- AX 不可读并不等于不可输入；记录未知状态，不伪造确定结论。

## 报告呈现要求

- 保留现有设置入口：“自动保存诊断日志”和“导出诊断报告”。不另开一套模式。
- 首先给用户可理解的摘要，随后给证据、精确阶段和不确定性。
- 恢复成功不能计为失败；timeout 和 wait skipped 必须区分。
- 允许按 session 看“识别仍增长、提交停止”的时间线，但必须结合 pending queue 和正常停顿，不能仅凭计数不变判卡死。
- 关联 sourceBuild/sourceAppPath，避免把另一个旧 App 的会话当作新版本。
- 相同会话多次恢复可汇总数量和延迟分布，原始操作证据仍需可追溯。
- 旧日志缺字段应展示“未知/旧版未记录”，不得补零并据此断言未发生。
- 如果要纳入本次旧 trace，先做显式、只读的转换和来源标识；没有确证时不可自动关联 ASR session。

## 隐私和开关

- 不记录识别正文、输入框原文、剪贴板正文、音频、凭证、签名 URL。
- 沿用 SessionLogger：关闭持久化时不新增磁盘日志；当前内存证据可供导出。
- 新字段使用明确的数值/布尔/枚举，注意现有 sanitizer 会隐藏包含 text/message 等片段的键。
- 不绕过 sanitizer，也不把敏感内容搬进看似无害的字段。
- 对必要保留的历史证据不自动删除。

## 验收矩阵

| 场景 | 报告应证明 |
| --- | --- |
| AX 返回 0，下一次读回 5 而非 7 | 对应属性/操作/返回码/不匹配，不能说焦点变了 |
| 127 延迟恢复到 128 | 短暂反馈延迟恢复，非失败，无重复投递 |
| 持续选区不匹配且等待已发生 | 真正等待超时，展示实际预算和耗时 |
| 距投递 333ms，未进入等待 | wait skipped，原因明确，不能说等了 150ms |
| final 修订后出现 199/104 选区 | 能定位到具体替换操作及最后观测阶段 |
| 平滑路径长尾修订 | 深修订计数不再错误显示 0 |
| 真实切换应用或输入框 | 区分应用变化与元素变化，不标为普通滞后 |
| 日志关闭/重新开启 | 磁盘行为遵循开关，内存导出可用 |
| 两份 App 或不同 build 的日志混合 | 可归属到实际来源，不误判新版回归 |
| 旧日志缺新字段 | 缺失展示未知，不误当 0 |

需要测试从 TextTarget 经 TextInjector、SessionCoordinator、SessionLogger 到 DiagnosticReport 的实际传递；直接手工构造最终报告事件的测试不能单独证明采集链路已接通。

## 当前 RCA 的结论边界

已确认的结构性问题：发送器的 queue.sync 只串行化本地事件投递；KeyboardCharacterPacer/TextInjector 会在目标完成未确认时推进 visibleText/lastSubmittedText/expectedKeyboardSelection。AX 状态反馈异步到达，短延迟和长尾修订都能暴露这个完成语义缺口。

未确认的目标层原因：这次 104 字符选区究竟是还在处理、替换事件未生效、Shift/Unicode 事件交互，还是编辑器主动改变选区。需要上述操作级信息及受控复现；不能再靠增大等待常量宣称根治。

原会话后续应研究：有明确阶段与完成确认的输入操作、尚未完成时不发送下一次修改、合并新的 ASR 候选、真实焦点变化仍中止。是否使用当前键盘路径、其他目标支持的插入方式，须通过真实输入框实验决定，不属于此报告增强任务。
