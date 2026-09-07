# Rime 双账户迁移与同步工具

这个工具只面向当前 Mac，不修改 Squirrel 引擎，也不接入 Ollama、DeepSeek 或网络热词服务。`mac` 与 `mac2` 各自保留独立的 `~/Library/Rime`；普通配置通过共享 manifest 做双向增量同步，个人词频由 TencentVoiceMVP 的“Rime 词库管理”逐条审核后写入独立受控词库。

## 首次迁移

个人词库审核不再使用会自动合并远端数据的 Squirrel 原生“同步用户数据”。管理器只发布当前账户的快照，使用 `rime_dict_manager --backup rime_ice`，因此远端快照不会在审核前进入当前 userdb：

```sh
"/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_dict_manager" --backup rime_ice
```

如果只想先把稳定资源提取到工作区、不动共享目录，可以使用 `--capture-only`。这不会读取或写入 userdb 快照。

然后在本仓库根目录执行：

```sh
./scripts/rime-sync bootstrap \
  --source /Users/Shared/RimeMigration-20260904/Rime \
  --workspace "$PWD/rime"
```

这一步会把稳定资源保存到工作区，并初始化 `/Users/Shared/RimeSync`。`build/`、`trash/`、Windows 的 `weasel.yaml`、实时 `.userdb` 和旧同步快照不会进入工作区。`rime_ice.userdb.txt` 会进入共享的 Rime 原生 userdb 快照目录；`luna_pinyin` 与 `wanxiang_entry` 会进入 `legacy-userdata` 隔离档案。

确认共享结构和资源无误后，再为当前账户安装：

```sh
./scripts/rime-sync bootstrap \
  --source /Users/Shared/RimeMigration-20260904/Rime \
  --workspace "$PWD/rime" \
  --install \
  --rime-dir "$HOME/Library/Rime" \
  --installation-id mac2-main
```

安装会写入当前账户的 `installation.yaml`，其中 `installation_id` 使用当前账户的稳定 ID，`sync_dir` 固定为 `/Users/Shared/RimeSync/rime-userdata`。它不会复制实时 `.userdb`，避免两个 Squirrel 进程直接争用同一个数据库。

源账户 `mac` 需要在自己的登录会话中把已有安装指向同一个快照目录；不需要把 `mac` 的实时目录复制给 `mac2`：

```sh
./scripts/rime-sync configure \
  --rime-dir "$HOME/Library/Rime" \
  --installation-id af672354-60fc-458a-9254-b0a39c8132ea \
  --node mac
```

## 日常命令

```sh
./scripts/rime-sync status
./scripts/rime-sync sync --dry-run
./scripts/rime-sync sync
./scripts/rime-sync verify
./scripts/rime-sync restore --backup <备份ID>
```

`RimeSync sync` 只同步普通稳定资源：创建完整备份、扫描 YAML/Lua/OpenCC/受控词库，并以当前账户上一次同步看到的版本为共同基线做三方增量合并。不同位置的修改会合并到同一文件；同一片段重叠修改、缺少共同基线或两边内容不同且修改时间完全相同会进入冲突，不会用一方静默覆盖另一方。合并结果用原子替换落盘，最后在配置改变时调用 Squirrel `--reload`。它不会调用 Squirrel `--sync`，因此不会绕过审核导入远端 userdb。每个账户默认保留最近 10 份备份；词库维护界面可将数量改为任意正整数，设置从下一次创建备份时生效。`--dry-run` 不创建锁、不调用 Squirrel、不写 manifest 或文件。

TencentVoice 状态栏菜单中的“同步 Rime 皮肤”只同步 `squirrel.custom.yaml`；“同步 Rime 所有配置”和“一键同步所有配置”同步全部普通稳定资源。它们不会把实时 `.userdb` 直接放入共享目录；实时用户词库仍使用单独的“同步 Rime 词库”。如果当前账户还没有 `~/Library/Rime`，配置同步会先建立该账户自己的目录和安装标识，再从共享节点拉取资源。

个人词库维护在 TencentVoiceMVP 菜单栏的“Rime 词库管理…”中完成。管理器打开后只读取最近一次“同步 Rime 词库”生成的审核缓存，不再发布快照、合并 userdb 或重复备份，因此打开 4.7 万条记录会更快。需要交换两个账户的 userdb 时，单独点击菜单栏的“同步 Rime 词库”；它执行 Squirrel 原生同步、创建备份、重新生成当前快照并更新审核缓存。首次读取只建立历史基线，不自动清空或重建 4.7 万条记录。后续只把新增、`c` 增长、疑似噪音和待确认记录放入建议视图。界面使用标准多行选择、全选当前结果和清除选择，不再为每条历史记录创建复选框；累计次数、有效热度和最近活动使用五档滑块，低频或陈旧记录默认隐藏但不会自动删除。

“最近活动”只依据管理器观察到的 `c` 增长时间。首次导入的历史快照没有可靠的日历时间，会显示“历史未知”；在后续同步中实际观察到某词的 `c` 增长后，它才会出现在近一周、近一月等时间范围内。快照中的 `d/t` 重写本身不会被误判为新的输入活动。

人工动作包括保留动态学习、加入长期记忆、删除错误学习、本次跳过、永久忽略和需要人工确认。长期记忆写入独立的 `rime_managed.dict.yaml`，静态权重固定为 1，实际候选排序仍由 `rime_ice.userdb` 动态学习决定；`custom_phrase.txt` 不会被改写。删除错误学习使用 librime 负 `c` 墓碑，当前账户立即处理，另一账户在下次打开管理器时处理；永久忽略会持续生效。

窗口的“导出”菜单可以输出 RFC 4180 CSV、TXT、Markdown 和 JSON，均只包含当前筛选结果，供人工或 AI 离线分析；也可以导入带批次、快照摘要和稳定 ID 的 AI 提案。提案只进入待审核区，最终仍由窗口确认。工作区还提供只读的 stdio MCP server，详见 [rime-audit-mcp.md](rime-audit-mcp.md)；它没有直接应用 userdb 或恢复备份的工具。

同一文件的修改片段重叠、没有共同基线，或两边内容不同且文件修改时间完全相同，会把本地版本、共享版本和可用的基线记录写入 `config/conflicts/<备份ID>/`，保留当前生效文件并将该路径加入 `pausedPaths`；不会静默覆盖。人工处理完冲突后，再从 manifest 中移除对应的 `pausedPaths` 条目并重新运行 `sync`。

## 两个账户

在 `mac` 账户执行时保留源安装 ID：

```sh
./scripts/rime-sync sync \
  --rime-dir /Users/mac/Library/Rime \
  --installation-id af672354-60fc-458a-9254-b0a39c8132ea \
  --node mac
```

在 `mac2` 账户执行时使用 `mac2-main` 和 `--node mac2`。两个账户都可以访问 `/Users/Shared/RimeSync`，但不要把该目录直接设置成任一账户的实时 `~/Library/Rime`。

工具会把共享目录及其节点目录设置为 `staff` 组可读写并启用 setgid（目录权限 `2770`）；manifest 会设置为组可写，确保两个账户都能推进同步。若系统管理员策略禁止普通用户修改组属性，需要先由管理员确认 `/Users/Shared` 的所属组为 `staff`。

每次审核应用或恢复前都会创建完整备份，默认保留最近 10 份；可在恢复备份窗口中按账户设置任意正整数，设置从下一次创建备份时生效。恢复界面会列出当前仍保留的全部备份，并在恢复失败时恢复应用前状态。首次审核只登记基线，不重建或清空当前 `userdb`。两个账户不会直接共用实时 `.userdb`，共享的是快照、审核状态和生成规则；另一账户在自己下次打开词库管理时处理跨节点动作并生成本地受控词库。
