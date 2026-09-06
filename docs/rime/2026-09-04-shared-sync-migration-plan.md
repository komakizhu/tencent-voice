---
title: Rime 双账户共享同步与完整迁移方案
slug: rime-shared-sync-migration-plan
summary: 在同一台 Mac 的 mac 与 mac2 账户之间迁移配置、共享个人词频，并保持两个 Squirrel 运行目录安全隔离。
description: 本文记录 Rime 配置清单、个人 userdb 迁移范围、共享同步目录的设计，以及后续安装和验证顺序。当前只记录方案与分析，不执行系统安装。
---

# Rime 双账户共享同步与完整迁移方案

## 当前目标

在同一台 Mac 上，把 `mac` 账户现有的鼠须管（Squirrel）配置、词库、主题定制和个人词频迁移到 `mac2`，并让两个账户的输入法可以通过共享同步目录合并个人词频。

平台范围仅限当前 macOS 和本人使用，不考虑 Windows 兼容性。

## 核心架构

```text
/Users/mac/Library/Rime       ← mac 账户的实时运行目录
/Users/mac2/Library/Rime      ← mac2 账户的实时运行目录
/Users/Shared/RimeSync         ← 两个账户共享的 Rime 同步目录
```

两个账户不能直接同时使用同一个实时 `~/Library/Rime`。实时用户词典数据库可能被两个 Squirrel 进程同时打开，存在锁冲突、写入覆盖或数据库损坏风险。

共享的应当是 Rime 的 `sync_dir`：每个账户将自己的用户词典导出为快照，另一个账户再把快照合并到本地 userdb。两个账户必须使用不同的 `installation_id`，例如：

```yaml
# mac 账户的 installation.yaml
installation_id: 'mac-main'
sync_dir: '/Users/Shared/RimeSync'

# mac2 账户的 installation.yaml
installation_id: 'mac2-main'
sync_dir: '/Users/Shared/RimeSync'
```

不要把两个账户的 `installation_id` 设成同一个值，否则同步快照可能互相覆盖。

## 要迁移的内容

### 必须保留

- 用户配置：`default.yaml`、`user.yaml`、各类 `*.custom.yaml`。
- 输入方案和词库：`*.schema.yaml`、`*.dict.yaml`。
- 自定义短语：`custom_phrase.txt`。
- 个人词频和用户词典：`*.userdb/`、`*.userdb.kct`（如果存在）。
- 用户词典快照：`*.userdb.txt`、同步目录中的快照。
- 可能影响行为的 `lua/`、`opencc/` 及其他用户目录内容（如果存在）。

### 不直接作为目标运行数据复制

- `build/`：部署生成的缓存，应在目标账户重新部署生成。
- 源账户的 `installation.yaml` 中的安装时间、版本和安装标识：内容可供参考，但目标账户应生成自己的安装信息，只保留/加入共享 `sync_dir` 配置。
- 正在运行时打开的实时 userdb：迁移前应退出鼠须管，或通过 Rime 快照机制导出。

## 已知配置清单

以下清单来自用户在 `mac` 账户终端执行的 `find` 输出。它证明文件存在，但尚未读取文件内容，因此“当前是否生效”仍需检查 `user.yaml`、方案配置和词典引用关系。

### 基础与用户状态

| 文件 | 当前判断 | 后续检查重点 |
| --- | --- | --- |
| `default.yaml` | Rime 全局默认配置或发行版配置 | 全局候选数、翻页、快捷键、用户词典相关默认值 |
| `user.yaml` | 当前用户状态 | 实际启用的输入方案、简繁状态和选项 |
| `installation.yaml` | 安装信息 | `installation_id`、`sync_dir`、Rime 版本；目标账户不能原样复用安装标识 |

### 鼠须管界面与样式

| 文件 | 当前判断 | 后续检查重点 |
| --- | --- | --- |
| `squirrel.yaml` | 鼠须管发行版/界面配置 | 当前候选面板默认设置 |
| `squirrel.custom.yaml` | 用户对鼠须管的覆盖配置 | CSS/主题、候选面板布局、字体、颜色、边距和行为定制 |

### 输入方案

| 文件 | 当前判断 | 后续检查重点 |
| --- | --- | --- |
| `rime_ice.schema.yaml` | 雾凇拼音主方案 | 当前使用的拼音方案、translator、用户词典、过滤器和快捷键 |
| `rime_ice.custom.yaml` | 雾凇拼音覆盖配置 | 词频、候选排序、用户词典开关、拼写/标点等修改 |
| `double_pinyin.schema.yaml` | 双拼基础方案 | 是否被其他双拼方案继承或直接启用 |
| `double_pinyin_abc.schema.yaml` | ABC 双拼变体 | 是否出现在方案选单 |
| `double_pinyin_flypy.schema.yaml` | 小鹤双拼变体 | 是否出现在方案选单 |
| `double_pinyin_mspy.schema.yaml` | 微软双拼变体 | 是否出现在方案选单 |
| `double_pinyin_sogou.schema.yaml` | 搜狗双拼变体 | 是否出现在方案选单 |
| `double_pinyin_ziguang.schema.yaml` | 紫光双拼变体 | 是否出现在方案选单 |
| `radical_pinyin.schema.yaml` | 部件/拆字相关方案 | 是否为备用方案，及其词典依赖 |
| `melt_eng.schema.yaml` | 英文输入方案 | 是否实际使用及其用户词典名称 |
| `t9.schema.yaml` | T9/九宫格方案 | 是否实际使用及其词典依赖 |

### 词库与自定义短语

| 文件 | 当前判断 | 后续检查重点 |
| --- | --- | --- |
| `rime_ice.dict.yaml` | 雾凇拼音词库 | 词典名称、版本、词频字段和是否被主方案引用 |
| `wanxiang_entry.dict.yaml` | 万象相关的自定义/衍生词库文件 | 文件头、`import_tables`、词典名称及是否被某个 schema 引用；不能仅凭文件名认定它是标准上游文件 |
| `radical_pinyin.dict.yaml` | 部件/拆字方案词库 | 与 `radical_pinyin.schema.yaml` 的引用关系 |
| `melt_eng.dict.yaml` | 英文词库 | 与 `melt_eng.schema.yaml` 的引用关系 |
| `custom_phrase.txt` | 用户自定义短语 | 编码、排序字段和是否配置为 active/prompt 词典 |

### 尚未出现在这次输出中的内容

这次命令只列出了顶层普通文件，以下项目不能据此判断不存在：

- `*.userdb/` 或其他 userdb 数据库目录；
- `*.userdb.txt` 用户词典快照；
- `sync/` 同步目录及其 installation ID 子目录；
- `build/`、`trash/`、`log/` 等运行或部署目录；
- `lua/`、`opencc/`、隐藏文件和符号链接。

其中 `*.userdb/` 和 `*.userdb.txt` 是个人词频迁移的关键，必须递归检查。

## 快照检查后的确认结果

已读取 `/Users/Shared/RimeMigration-20260904/Rime` 的配置和目录结构。当前快照约 583 MB，说明它是一个完整的运行目录，而不是只有几个定制文件的轻量配置。

### 个人词频已经存在

确认发现以下实时用户词典数据库：

- `rime_ice.userdb/`：约 2.1 MB，是当前最重要的个人中文词频库；同步快照 `rime_ice.userdb.txt` 约 36,386 行、1.6 MB。
- `luna_pinyin.userdb/`：约 24 KB；同步快照约 12 行，可能是旧方案或历史遗留数据。
- `wanxiang_entry.userdb/`：约 20 KB；同步快照约 14 行，可能是旧的万象入口方案数据。

同步目录目前只有源账户的 installation ID：

```text
af672354-60fc-458a-9254-b0a39c8132ea
```

源账户的 `installation.yaml` 尚未配置 `sync_dir`，所以这个 `sync/` 目前是源账户 Rime 用户目录下的默认同步区，不是两个账户共用的 `/Users/Shared/RimeSync`。迁移时应保留这些快照，并在两个账户中重新设置共享同步目录。

### 当前实际组合

当前主体可以确定为：

```text
雾凇拼音 rime_ice
├── cn_dicts：8105、base、ext、tencent、others
├── wanxiang_dicts：基础、联想、地名、人名、诗词、数学等 11 个分类词库
├── wanxiang-lts-zh-hans.gram：约 197 MB 的语法模型
├── Lua：27 个脚本，包含错音提示、置顶、长词、英文处理、日期、计算器等
└── OpenCC：Emoji、简繁转换等资源
```

`rime_ice.dict.yaml` 已直接挂载腾讯词向量词库和 `wanxiang_dicts/*`。因此现在的主要候选来源不是 `wanxiang_entry.dict.yaml`，而是 `rime_ice` 主词典加上万象分类词库。

### 当前方案和行为

- `default.yaml` 的方案选单包含 8 个可选方案：雾凇全拼、T9、自然码、智能 ABC、微软、搜狗、小鹤、紫光双拼。
- 各双拼方案基本是从 `rime_ice.schema.yaml` 复制后改造拼写规则，仍然挂载 `rime_ice` 主词库。
- `t9.schema.yaml` 通过 `__include: rime_ice.schema.yaml:/` 继承雾凇配置。
- `user.yaml` 目前只有 `last_build_time`，没有记录当前选中的方案，因此仅凭该文件不能判断用户平时实际使用的是全拼还是某种双拼。
- `rime_ice.custom.yaml` 启用了 `wanxiang-lts-zh-hans` 语法模型，并设置了联想惩罚、同音词/同形词数量上限为 5。
- 该文件实际设置 `translator/contextual_suggestions: true`，但注释描述的是“设为 false 后减少玄学联想”。配置值和注释意图不一致，这是后续解释候选异常时需要重点验证的地方。
- `custom_phrase` 使用 `stabledb`，注释明确说明它是只读数据库、不会动态调频；真正的个人动态词频主要应看 `rime_ice.userdb`。
- `melt_eng` 和部件反查方案明确关闭了用户词典，不应把它们的行为误认为中文个人词频。

### 样式已经确认

你之前提到的“CSS 修改”实际上是鼠须管 YAML 样式覆盖，不是网页 CSS。`squirrel.custom.yaml` 中已经确认：

- 主题为 `blue_reverie`，深色主题为 `blue_reverie_dark`；
- 横向候选、候选格式为 `[编号]. [候选] [注释]`；
- 使用苹方，字号 16；
- 半透明、模糊、圆角、阴影、候选间距和行距均有定制；
- 开启记忆窗口大小，并隐藏翻页提示。

### 需要保留但不能直接认定为当前生效

- `wanxiang_entry.dict.yaml`、`wanxiang_entry.userdb` 和对应快照存在，但在源目录的 schema/config 中没有找到对 `wanxiang_entry` 的引用；它曾经被编译成 `build/wanxiang_entry.table.bin`，更像历史方案或遗留用户数据。迁移时先保留，不应未经确认就把它合并进 `rime_ice.userdb`。
- `lua/cold_word_drop/` 目录存在，但当前源 schema 中没有找到对它的挂载引用；它可能是备用功能或未启用模块。
- `rime-mate-config/rime-mate` 是 arm64 可执行程序，版本文件为 `v1.0.0`。`Rime配置助手.command` 把路径硬编码为 `/Users/mac/Library/Rime`，迁移到 `mac2` 后不能直接使用，需要单独适配或暂不纳入运行流程。
- `weasel.yaml` 是 Windows 小狼毫配置。由于本项目只服务 macOS，它可以作为来源档案保留，但不应作为 mac2 鼠须管的生效配置。

## 当前分析结论

这套配置的关键不是单独的“雾凇词库”，而是一个已经组合好的 Rime 发行目录：雾凇方案负责输入逻辑，`rime_ice.userdb` 保存个人中文词频，万象语法模型负责上下文联想，腾讯词向量和万象分类词库负责扩展候选，Lua 和鼠须管 custom YAML 负责行为与外观。

因此后续迁移必须以“保留整个组合、重新生成目标账户 build、单独迁移三套 userdb、再建立共享快照同步”为原则，而不是只复制 `rime_ice.dict.yaml`。

## 后续实施顺序

1. 在 `mac` 账户退出鼠须管，建立只读意义上的完整迁移快照，保留所有配置、词库、userdb 和快照。
2. 递归检查 userdb、快照、同步目录和所有可能的 Lua/OpenCC 资源。
3. 根据 `user.yaml` 与 schema 引用关系确认实际启用方案，而不是把所有列出的方案都误判为正在使用。
4. 把配置和词库安装到 `/Users/mac2/Library/Rime`，目标账户重新生成 `build/`。
5. 在两个账户中设置同一个 `/Users/Shared/RimeSync`，并设置不同的 `installation_id`。
6. 用 Rime 的用户词典快照合并机制导入个人词频，验证常用词、用户短语和词频排序。
7. 以后再增加 macOS `launchd` 定时同步，让任一账户产生的词频变化被另一个账户自动合并。

## 重要限制

共享同步不是实时数据库镜像。一个账户刚刚学到的词，首先写入该账户自己的 userdb；执行同步后才进入共享快照，另一个账户下一次同步时再合并。因此“只更新一个词频”可以实现，但底层仍然是“单边产生变化 + 双边合并”，不是两个 Squirrel 进程共同打开同一个 userdb。

当前文档只记录方案和配置分析，不执行系统目录创建、权限修改、配置安装或输入法重载。
