# cai_tool_app

这个目录是 Flutter App 本体。以后继续改这里时，先看总入口：

- [项目速查卡](../AGENT_BRIEF.md)
- [API 说明](API_CONTRACT.md)
- [数据字典](docs/db.md)
- [iOS 上架清单](docs/RELEASE_CHECKLIST.md)
- [隐私政策](docs/PRIVACY_POLICY.md)

## 本地启动

```powershell
flutter pub get
flutter run -d chrome --dart-define=CAIMASTER_API_BASE_URL=https://api.cclloo.com
```

## 打包

```powershell
flutter build apk --release --dart-define=CAIMASTER_API_BASE_URL=https://api.cclloo.com
```

## 开发约定

- 先改一个明确目标，再看效果。
- UI 优先保持清爽，不重复堆功能。
- 如果接口或字段变了，优先同步 `API_CONTRACT.md` 和 `docs/db.md`。

## 配置方式

- 服务器地址可通过 `--dart-define` 覆盖；生产默认使用 `https://api.cclloo.com`。
- 安装包不包含长期 API Token。首次启动在“设置 > 激活设备”输入一次性激活码。
- 刷新凭据保存于设备 Keychain，访问凭据由服务器签发并短时失效。
