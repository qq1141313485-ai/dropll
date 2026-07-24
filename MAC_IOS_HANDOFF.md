# 竞球镜 iOS 真机测试交接说明

## 当前目标

在 MacBook 上构建 Flutter iOS 应用，并安装到用户自己的 iPhone 进行测试。

## 工程状态

- Flutter 工程根目录：当前目录
- 应用名称：竞球镜
- iOS 工程：`ios/Runner.xcworkspace`
- Bundle Identifier：`com.caimaster.caiToolApp`
- 最低 iOS 版本：13.0
- 应用版本：`1.0.0+3`
- 生产 API：`https://api.cclloo.com`
- iOS `Info.plist` 使用默认 ATS 策略，无需 HTTP 例外
- iOS AppIcon 已由 `assets/branding/app_icon.png` 生成
- App 使用公开只读赛事接口；安装后无需注册、登录或激活

## 严格限制

- 不修改后端、数据库或生产服务器。
- 不把 API Token、Apple ID 密码、证书私钥提交到 Git。
- 不以仓库旧版本覆盖当前迁移包中的 Flutter 源码。

## Mac 环境准备

1. 从 App Store 安装最新版 Xcode，并至少启动一次。
2. 在 Xcode 的 Settings > Accounts 中登录用户自己的 Apple ID。
3. 安装 Flutter SDK，并保证 `flutter doctor` 能识别 Xcode。
4. 安装 CocoaPods（Apple Silicon 与 Intel 均可使用 Homebrew）：

   ```bash
   brew install cocoapods
   ```

5. 在工程根目录执行：

   ```bash
   flutter pub get
   cd ios
   pod install
   cd ..
   ```

## Xcode 真机签名

1. 用 Xcode 打开 `ios/Runner.xcworkspace`，不要打开 `.xcodeproj`。
2. 选择 Runner target > Signing & Capabilities。
3. 开启 Automatically manage signing。
4. Team 选择用户自己的 Personal Team 或开发者团队。
5. 如果 Bundle Identifier 冲突，只修改为该 Apple ID 下唯一的反向域名标识。
6. 数据线连接 iPhone，在手机上信任 Mac，并开启“设置 > 隐私与安全性 > 开发者模式”。

## 生产配置构建

生产包默认使用 HTTPS API；不要传入或注入 API Token。安装后可直接使用公开数据服务。

```bash
flutter run \
  --dart-define=CAIMASTER_API_BASE_URL=https://api.cclloo.com
```

如果要生成归档：

```bash
flutter build ipa \
  --dart-define=CAIMASTER_API_BASE_URL=https://api.cclloo.com
```

免费 Personal Team 适合连接自己的 iPhone 调试；TestFlight 或长期分发需要 Apple Developer Program。

## Mac 上交给 Codex 的任务

请在 Mac 的 Codex 中打开本目录，然后发送：

> 接管竞球镜 Flutter iOS 真机测试。先阅读 MAC_IOS_HANDOFF.md，只检查环境和签名，不修改业务代码；配置完成后使用生产 HTTPS 配置构建并安装到已连接的 iPhone。禁止输出或提交任何激活码、Token 或私钥。
