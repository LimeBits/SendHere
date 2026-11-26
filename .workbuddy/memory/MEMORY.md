
- 打包：iOS/macOS 可在助手侧打包，前提是已设 Xcode 默认项 IDEPackageSupportDisableManifestSandbox / IDEPackageSupportDisablePluginExecutionSandbox = YES，并以无沙箱方式运行 Scripts/package-*.sh。
- Git 规则（用户要求）：多做小粒度提交，便于回退。每完成一个独立改动（修 bug、加功能、改脚本）且测试/构建通过后，就单独提交到本地；只暂存相关文件，不提交 .workbuddy/。每发一个新版本（build 号递增）也提交一次。
- **禁止自动推送远程（用户 2026-11-26 明确要求）**：`git push`、`git push --tags`、`gh release create`、Gitea release API，全部只能在用户明确说"推送/发布"时执行。默认只提交到本地，打完包就停。打包 ≠ 发布。违反过多次，务必遵守。
- 打包交付（用户要求）：每次打包完成后，必须告知产物所在文件夹（/Users/bruce/Desktop/b-vibe/SendHere/dist/）和完整文件名，并用 present_files 发出来，不能只说“已打包”。
