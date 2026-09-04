# Rime 皮肤切换

雾凇负责输入方案，鼠须管的皮肤配置位于 `rime/squirrel.custom.yaml` 的
`preset_color_schemes`。当前配置包含 `blue_reverie`、`paper`、`mint` 和
`midnight` 四组皮肤，每组都有一个亮色主题和一个同名的 `_dark` 深色主题。

## 切换

软件启动后，点击菜单栏里的“语”图标，打开“Rime 皮肤”子菜单即可按名称
选择皮肤；当前皮肤会带勾，macOS 深色模式会自动使用对应的 `_dark` 版本。
下面的命令行入口仍然保留，适合自动化或排查问题。

脚本默认操作当前用户的 `~/Library/Rime/squirrel.custom.yaml`：

```bash
scripts/rime-theme list
scripts/rime-theme current
scripts/rime-theme use paper
scripts/rime-theme next
```

`use paper` 会同时设置 `color_scheme: paper` 和
`color_scheme_dark: paper_dark`，然后调用鼠须管的 `--reload` 重新部署。
如果只想改文件、不立即重新部署，可以加 `--no-reload`。当你用
`RIME_DIR` 指向仓库等非实时目录时，脚本也会自动跳过重新部署，避免改了
仓库却重载另一套配置。

如果只是编辑仓库中的配置，可以指定目录：

```bash
RIME_DIR="/Users/mac2/Documents/ChatGPT/Rime+腾讯语音+自适应词库/rime" \
  scripts/rime-theme use mint --no-reload
```

## 添加新皮肤

在 `patch` 下用 `preset_color_schemes/<主题名>` 增加一个主题，例如
`sunset`；如果需要跟随 macOS 深色模式，再增加 `sunset_dark`。脚本会自动
发现新主题：

```yaml
patch:
  "preset_color_schemes/sunset":
    name: "日落 / Sunset"
    back_color: '0xE8F0FF'
    candidate_text_color: '0x302018'
    hilited_candidate_text_color: '0xFFFFFF'
    hilited_candidate_back_color: '0x4060D0'
```

每套皮肤除了颜色，也可以单独覆盖字体、圆角、候选布局和候选格式；如果只
想换颜色，把这些通用外观放在 `style` 下即可。皮肤颜色使用 Rime 的 BGR
顺序，而不是网页 CSS 的 RGB 顺序。网页中的
`#D06A40` 应写成 `0x406AD0`；带透明度时使用 `0xAABBGGRR`。增加或修改
主题后，执行 `scripts/rime-theme use sunset`，或从鼠须管菜单重新部署。
