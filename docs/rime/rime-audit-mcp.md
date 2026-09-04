# Rime 审核 MCP

RimeAuditMCP 是一个只面向本机的 stdio MCP server。它读取 TencentVoiceMVP 生成的审核批次，供 AI 分页查看或导出 CSV，并把经过批次校验的审核提案写入共享审核状态。

它不提供 apply、restore 或任何直接写入 userdb 的工具。提案写入后，仍必须回到腾讯语音菜单栏程序的“Rime 词库管理”窗口进行预览和最终确认；MCP 客户端的工具调用不等于词库修改授权。

## 提供的工具

| 工具 | 作用 |
| --- | --- |
| rime_audit_summary | 读取当前批次、来源快照、状态数量和提案数量 |
| rime_audit_list | 按视图、累计次数、有效热度、最近活动、搜索和分页读取记录 |
| rime_audit_export | 导出 RFC 4180 CSV，供 AI 离线分析 |
| rime_audit_submit_proposal | 提交带批次和快照摘要的提案 CSV，只写待审核状态 |
| rime_audit_preview | 查看提案汇总并判断当前批次是否过期 |

rime_audit_list 的筛选值与界面一致：

- view: recommendations、recent、noise、permanent、ignored、all
- commit_band: all、3、10、30、100
- heat_band: all、top_50、top_25、top_10、top_1
- activity_band: all、year、six_months、month、week

列表默认一次返回 100 条，使用 offset 和 limit 分页，单次最多 1000 条。MCP server 不会把日志写到 stdout；错误和诊断信息写到 stderr。

## 本地启动

在工作区中先运行菜单栏程序的 Rime 词库管理并生成审核批次，然后启动：

~~~sh
./scripts/rime-audit-mcp \
  --rime-dir "$HOME/Library/Rime" \
  --shared-root "/Users/Shared/RimeSync" \
  --installation-id "mac2-main"
~~~

脚本会构建 RimeAuditMCP（若尚未构建），随后把 stdio 交给 MCP 协议。它不会修改 Codex、ChatGPT 或其他客户端的 MCP 配置；客户端配置需要用户自行决定和添加。

提案 CSV 必须使用 rime_audit_export 生成的 batch_id、snapshot_digest 和 entry_id。允许的动作是：

keep_dynamic、promote_permanent、delete_learned、ignore_permanent、review_manually。

skip_once 不允许由 AI 提交，因为它只属于当前人工审核会话。批次过期、重复 ID、未知 ID、未知动作或置信度不在 0...1 内时，提交会被拒绝。
