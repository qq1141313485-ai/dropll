# 球镜 iOS 上架执行文档

## 工程位置

```text
/Users/drop/Documents/Codex/2026-08-31/jingqiujing-ios
```

当前版本：`1.0.1`，构建号：`6`  
Bundle ID：`com.caimaster.jingqiujing`

## 1. 准备环境

在 Mac 的 Codex 终端执行：

```bash
cd /Users/drop/Documents/Codex/2026-08-31/jingqiujing-ios
which flutter
flutter --version
which pod || sudo gem install cocoapods
```

## 2. 安装依赖并检查

```bash
cd /Users/drop/Documents/Codex/2026-08-31/jingqiujing-ios
/Users/drop/development/flutter/bin/flutter clean
/Users/drop/development/flutter/bin/flutter pub get
cd ios
pod install
cd ..
/Users/drop/development/flutter/bin/flutter test
```

如果 `pod install` 报 Ruby 权限错误，改用：

```bash
sudo gem install cocoapods
```

不要把 `android/key.properties` 或 `.jks` 文件上传到 iOS 工程或 GitHub。

## 3. Xcode 签名设置

打开工作区，不要打开 `.xcodeproj`：

```bash
open ios/Runner.xcworkspace
```

在 Xcode 中：

1. 选择项目 `Runner`，Target 选择 `Runner`。
2. Signing & Capabilities 中勾选 Automatically manage signing。
3. Team 选择公司对应的 Apple Developer Team。
4. Bundle Identifier 保持 `com.caimaster.jingqiujing`。
5. Deployment Target 保持 iOS 15.0。
6. 设备范围保持 iPhone，方向保持竖屏。
7. 检查 `Info.plist` 中名称为“球镜”，隐私政策和支持网址可正常打开。

## 4. 真机检查

连接 iPhone，在 Xcode 选择真机后执行 Product > Run。重点检查：

- 冷启动和启动页
- 首页、比赛详情和 `90+` 显示
- 保存方案后按钮显示“已保存”
- 方案图片默认居中、下载成功
- 设置页版本号和数据清理
- 隐私政策、服务中心链接

## 5. Archive 和 TestFlight

确认真机检查通过后：

1. Xcode 菜单 Product > Archive。
2. 打开 Organizer，选择最新 Archive。
3. Validate App。
4. Distribute App > App Store Connect > Upload。
5. 等待处理完成后，在 App Store Connect 的 TestFlight 中添加内部测试员。

## 6. App Store Connect 信息

- App 名称：`球镜`
- 版本：`1.0.1`
- Copyright：`2026 重庆阅江数字科技有限公司`
- 主分类：体育
- 副分类：工具
- 隐私政策：`https://api.cclloo.com/privacy`
- 支持网址：`https://api.cclloo.com/support`
- 营销网址：`https://cclloo.com/`

提交前必须确认：赛事数据和计划图片具有可核验的展示/再分发授权；年龄分级和 App Privacy 按实际行为如实填写。

## 常见问题

- `CocoaPods not installed`：安装 CocoaPods 后重新执行 `pod install`。
- `No signing certificate`：在 Xcode 登录 Apple ID，选择正确 Team，或让公司管理员授予发布权限。
- Archive 失败：确认打开的是 `Runner.xcworkspace`，不是 `Runner.xcodeproj`。
- 版本号不对：确认 `pubspec.yaml` 为 `version: 1.0.1+6`，执行 `flutter clean` 后重新 Archive。
