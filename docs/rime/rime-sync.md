# Rime 手动配置存档

Rime Voice 不再自动跨账户同步配置。需要迁移到另一台 Mac 或另一个 macOS 账户时，在菜单栏使用“导出所有配置…”和“导入所有配置…”。这两个入口交换的是经过白名单筛选的便携存档，不会读写旧的 `/Users/Shared/RimeSync`。

存档为单个 `.rimevoiceconfig` 文件，含格式版本、路径清单、文件大小与 SHA-256 校验。它覆盖 `custom_phrase.txt`、皮肤、方案 YAML、词典、Lua、OpenCC、语法模型、配置助手及受控长期词典 `rime_managed.dict.yaml`。导入前会完整校验并在可滚动清单中展示所有新增、替换和相同项；目标账户未列入存档的文件会保留，确认后先备份受影响文件，再写入并重新加载 Rime。若存档包含 Lua 或配置助手脚本，会额外要求确认来源可信。若写入或重新加载失败，程序恢复文件和本机审核状态并重新加载；中断后下次启动会提示恢复导入前版本，不会把缺少归档载荷的部分导入标记为完成。全部内容相同的重复导入不会重写、备份或重新加载。

存档明确排除 `installation.yaml`、`build/`、`sync/`、实时 `.userdb`、日志、凭据、机器身份、共享审核历史和审核缓存。导入保留目标账户自己的 installation ID 与其余本机数据。长期词典文件会迁移，但词库审核历史不会跟随账户迁移。

## 本机词库维护

“Rime 词库管理…”仍只管理当前账户。打开窗口只读取当前账户已有的审核数据，不生成快照或修改 `installation.yaml`。只有用户明确点击“刷新本机快照”时，程序才先在当前账户 Application Support 下保存本机备份，然后把本机 `installation.yaml` 的 `sync_dir` 指向当前账户私有快照目录（保留已有 `installation_id`），再生成本机审核快照。它不会调用 Squirrel `--sync`，不会合并其他账户的 userdb 快照，也不会重建实时 `.userdb`。审核缓存与备份存放在 `~/Library/Application Support/Rime Voice/Review`；旧共享审核数据保持原样，不自动迁入。

手动审核与加词仍可修改当前账户的受控长期词典并重新加载 Rime。导入包含 `rime_managed.dict.yaml` 的存档后，会用导入词典重建本机审核词条状态，避免旧审核缓存把导入内容改回去。若导入的主词典需要挂接受控词典，程序会在同一可回滚事务中保存并更新 `rime_ice.dict.yaml`。

## 旧命令

`RimeSync status`、`conflicts` 和 `verify` 仅保留只读历史诊断能力。默认诊断目录是当前账户的 `~/Library/Application Support/Rime Voice/Review`；查看旧共享数据时，必须显式指定 `--shared-root /Users/Shared/RimeSync`，例如 `RimeSync status --shared-root /Users/Shared/RimeSync`。该选项只改变只读诊断的数据来源，不会启用写入。`configure`、`sync`、`resolve` 和 `restore` 已停用；`bootstrap` 仅允许 `--capture-only`，不会初始化共享目录或安装配置。`scripts/rime-refresh-snapshot` 也已停用，改用词库管理窗口里的“刷新本机快照”。不会自动清理旧共享目录、UUID 节点或历史文件。

Mac1 的实际配置和输入效果仍须在 Mac1 登录会话中另行验收。共享副本或导出的存档不能代替对目标账户实时 Rime 目录的验证。
