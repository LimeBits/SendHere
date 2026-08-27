# SendHere（传到这）

> 手机扫码，把文字、链接、照片和文件直接传到这台电脑。  
> 无需登录，不装手机 App，数据仅在当前局域网设备之间传输。

产品方向与正式技术决策见 [`docs/product-strategy.md`](docs/product-strategy.md)。

## 技术栈

- 桌面端：Flutter + Dart（macOS、Windows）
- 本地服务：Dart `dart:io`、Shelf、WebSocket
- 手机端：桌面 App 内置的 HTML / CSS / Vanilla JavaScript 页面
- 手机浏览器不依赖公网 CDN 或第三方服务。

## 当前 MVP

已实现源代码：

- Dart 本地 HTTP 与 WebSocket 服务；
- 每次启动生成的 30 分钟临时 token；
- QR Code 局域网连接地址；
- 手机网页发送文本、上传图片/文件；
- 桌面端向手机发送文本与文件下载链接；
- 内置 WebSocket 实时事件。

> 当前开发机尚未安装 Flutter/Dart SDK，因此本仓库中的 Flutter 工程尚未在本机完成编译运行验证。

## 开发环境

安装 Flutter（包含 Dart），并确认 macOS / Windows 桌面环境：

```bash
flutter doctor
flutter pub get
flutter create --platforms=macos,windows .
flutter run -d macos
```

`flutter create` 只生成平台壳文件，不会覆盖 `lib/` 与 `assets/` 中的 SendHere 源码；执行后请检查 `macos/Runner/Configs/AppInfo.xcconfig` 和 Windows 应用显示名，将产品名改为 `SendHere`。

## 打包

macOS Release 构建：

```bash
flutter build macos --release
./Scripts/package-macos-dmg.sh
```

DMG 与 SHA-256 校验文件会输出到 `dist/`。

正式发布前需使用 Apple Developer 的 Developer ID Application 证书签名 Flutter 生成的 `.app`，然后公证：

```bash
./Scripts/notarize-macos.sh dist/SendHere-<version>-build<build>-<timestamp>.dmg
```

首次使用公证服务可保存凭据到本机钥匙串：

```bash
xcrun notarytool store-credentials "sendhere-notary" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

证书、Team ID、Apple ID、公证密码和其他密钥均不得提交到仓库。
