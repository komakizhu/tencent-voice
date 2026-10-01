# App Build Numbers

- `Resources/Info.plist` 的 `CFBundleVersion` 是持久 Build 号。修改代码后，为测试新版本运行 `./scripts/build-app.sh`；默认测试模式每次完整编译加 1，并保留递增后的号码。每组 App 修改后完整编译、验证 `.app`，并提供最新可运行文件的链接。
- 修改完成并提交后，定稿、发布、释放和覆盖都复用已提交的 Build 号，不因这些操作再次递增。只有提交后又修改代码、需要测试新版本时，才进入下一次递增的测试构建。
- 复用号码进行完整编译时设置 `TVMVP_BUILD_MODE=keep`；`scripts/install-app.sh` 和 GitHub Actions Release 必须使用此模式。该模式不得修改 `Resources/Info.plist`。
- Build 号只作为 App 内部元数据和测试产物的区分依据；应用界面、正式发布包内的 App 名称及安装名称均不显示 Build 号。
