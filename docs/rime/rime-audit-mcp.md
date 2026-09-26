# Rime 审核 MCP

RimeAuditMCP 读取当前账户的 Rime 词库审核缓存，可分页浏览、导出 CSV 并提交待审核提案。审核状态只写入当前账户的 `~/Library/Application Support/Rime Voice/Review`，不访问或修改 `/Users/Shared/RimeSync`。它不会生成 userdb 快照，也不会调用 Squirrel `--sync`。

## 提供的工具

| 工具 | 作用 |
| --- | --- |
| rime_audit_summary | 读取当前批次、快照摘要、状态数量和提案数量 |
| rime_audit_list | 按视图、次数、热度、活动时间和搜索条件分页读取记录 |
| rime_audit_export | 导出当前审核结果 CSV |
| rime_audit_submit_proposal | 校验并保存当前账户的待审核提案，不会执行提案 |
| rime_audit_preview | 预览提案并判断当前批次是否过期 |

MCP 不提供应用提案、修改 userdb 或恢复备份的工具。实际审核操作仍须在 Rime Voice 的词库管理界面确认。旧账户的共享审核历史不会自动导入。

## 本地启动

先在 Rime Voice 打开“Rime 词库管理…”并刷新本机快照，再启动：

~~~sh
./scripts/rime-audit-mcp --rime-dir "$HOME/Library/Rime"
~~~

`--shared-root` 已停用；如提供该参数，服务会明确拒绝启动而不会回退到共享目录。客户端连接配置仍需用户自行添加。

提案必须带有当前批次的 `batch_id`、`snapshot_digest` 和有效词条 ID。允许的动作包括 `keep_dynamic`、`promote_permanent`、`replace_entry`、`delete_learned`、`ignore_permanent` 和 `review_manually`。提交只写入当前账户待审核状态；批次过期、重复或未知 ID、无效动作及置信度范围错误均会被拒绝。
