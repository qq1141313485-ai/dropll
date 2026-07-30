# 竞球镜

竞球镜 Flutter App，维护 iOS、Android 和 Web 三个平台，以及配套的计划内容服务。

## 项目入口

- Flutter 共用代码：`lib/`
- iOS 工程：`ios/Runner.xcodeproj`
- Android 工程：`android/`
- Web 工程：`web/`
- API 契约：`API_CONTRACT.md`
- 数据字典：`docs/db.md`
- 上架清单：`docs/RELEASE_CHECKLIST.md`
- 隐私政策：`docs/PRIVACY_POLICY.md`
- 计划内容服务：`server/plan_content/README.md`
- 正式 Logo 源图：`assets/branding/app_icon_master_1024.png`

## 多平台同步规则

`lib/`、`assets/`、`pubspec.yaml` 中的页面、业务逻辑、接口和共用资源会同步到 iOS、Android 和 Web。以下内容需要分别配置和验证：

- iOS：签名、权限、AppIcon、分享和文件保存。
- Android：签名、权限、启动图、通知和文件保存。
- Web：浏览器权限、下载、跨域、缓存和 PWA 图标。

涉及插件或原生能力的功能，不能只测试 iOS 后直接认为另外两个平台可用。

## 开发与验证

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d <device-id>
```

生产 API 默认是 `https://api.cclloo.com`。需要切换测试环境时使用：

```bash
flutter run -d <device-id> \
  --dart-define=CAIMASTER_API_BASE_URL=https://example.com
```

## 构建

```bash
# iOS
flutter build ios --release

# Android 测试 APK
flutter build apk --release

# Web
flutter build web --release
```

iOS 使用 Flutter Swift Package Manager 集成，不使用 CocoaPods。发布 Android 前必须配置正式签名，不能使用测试签名。

## 开发约定

- API 或字段变化时同步维护 `API_CONTRACT.md` 和 `docs/db.md`。
- 不提交服务器密码、API Token、签名密码、Apple ID 密码或证书私钥。
- 线上文件修改前创建时间戳备份。
- 构建和安装前核对平台、版本号、构建模式与生成时间。
- App 使用公开只读赛事接口，不要求注册、登录或激活。
