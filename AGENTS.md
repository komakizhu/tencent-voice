# App Build Numbers

- `Resources/Info.plist` 的 `CFBundleVersion` 是此工作区的持久 Build 号。每次完整构建可运行 App 时，运行 `./scripts/build-app.sh`，让脚本将 Build 号加 1，并用新号命名 `.app`。
- 构建后保留 `Resources/Info.plist` 中的新 Build 号，不要还原、复用旧号或覆盖旧 Build 的产物。后续修改再次构建时，从上次成功产物的号码继续加 1。
- 此工作区的 Build 号已按用户确认的序号补齐；以 `Resources/Info.plist` 中的号作为下一次构建的起点。
- 每组 App 修改后完整编译，验证生成的 `.app`，并在回复中提供最新可运行文件的链接。
