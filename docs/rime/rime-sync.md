# Rime 双账户迁移与同步工具

这个工具只面向当前 Mac，不修改 Squirrel 引擎，也不接入 Ollama、DeepSeek 或网络热词服务。`mac` 与 `mac2` 各自保留独立的 `~/Library/Rime`；普通配置通过共享 manifest 做双向增量同步，Rime 个人词频只通过原生快照同步。

## 首次迁移

源账户的 `rime_ice.userdb` 比已有快照更新。正式迁移前，先以 `mac` 账户执行一次 Squirrel 的同步入口，让 Rime 生成最新快照：

```sh
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --sync
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

`sync` 的顺序是：取得原生 userdb 快照、创建完整备份、扫描普通资源、按最后修改时间合并、用原子替换落盘，最后在配置改变时调用 Squirrel `--reload`。每次同步保留最近 3 份备份。`--dry-run` 不创建锁、不调用 Squirrel、不写 manifest 或文件。

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
