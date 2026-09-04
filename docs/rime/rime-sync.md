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

`RimeSync sync` 只同步普通稳定资源：创建完整备份、扫描 YAML/Lua/OpenCC/受控词库、按最后修改时间合并、用原子替换落盘，最后在配置改变时调用 Squirrel `--reload`。它不会调用 Squirrel `--sync`，因此不会绕过审核导入远端 userdb。每次同步保留最近 3 份备份。`--dry-run` 不创建锁、不调用 Squirrel、不写 manifest 或文件。

个人词库维护在 TencentVoiceMVP 菜单栏的“Rime 词库管理…”中完成。打开后，程序只发布当前账户的 `rime_ice` 快照并读取共享快照；首次读取只建立历史基线，不自动清空或重建 4.7 万条记录。后续只把新增、`c` 增长、疑似噪音和待确认记录放入建议视图。界面使用标准多行选择、全选当前结果和清除选择，不再为每条历史记录创建复选框；累计次数、有效热度和最近活动使用五档滑块，低频或陈旧记录默认隐藏但不会自动删除。

人工动作包括保留动态学习、加入长期记忆、删除错误学习、本次跳过、永久忽略和需要人工确认。长期记忆写入独立的 `rime_managed.dict.yaml`，静态权重固定为 1，实际候选排序仍由 `rime_ice.userdb` 动态学习决定；`custom_phrase.txt` 不会被改写。删除错误学习使用 librime 负 `c` 墓碑，当前账户立即处理，另一账户在下次打开管理器时处理；永久忽略会持续生效。

窗口可以导出 RFC 4180 `rime-audit.csv` 供 AI 离线分析，也可以导入带批次、快照摘要和稳定 ID 的 AI 提案。提案只进入待审核区，最终仍由窗口确认。工作区还提供只读的 stdio MCP server，详见 [rime-audit-mcp.md](rime-audit-mcp.md)；它没有直接应用 userdb 或恢复备份的工具。

同一文件同一纳秒时间但内容不同，会把本地版本写入 `config/conflicts/<备份ID>/`，保留当前生效文件并将该路径加入 `pausedPaths`；不会静默覆盖。人工处理完冲突后，再从 manifest 中移除对应的 `pausedPaths` 条目并重新运行 `sync`。

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

每次审核应用或恢复前都会创建完整备份，最近保留 3 份；失败时恢复应用前状态。首次审核只登记基线，不重建或清空当前 `userdb`。两个账户不会直接共用实时 `.userdb`，共享的是快照、审核状态和生成规则；另一账户在自己下次打开词库管理时处理跨节点动作并生成本地受控词库。
