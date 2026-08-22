# 发布产物台账

本文只记录可复现的构建事实。没有来源 commit、构建配置和签名类型的产物只能称为
测试构建，不能据此判断商店提交版本已就绪。

| 日期 | 版本 | 平台 | 结果 | 来源 commit | 定位 |
| --- | --- | --- | --- | --- | --- |
| 2026-08-21 | `1.0.0+4` | Android Release APK | 构建并用于测试/部署 | 未记录，工作区有未提交改动 | 测试构建 |
| 2026-08-21 | `1.0.0+4` | Flutter Web Release | 构建并部署到 `/app/` | 未记录，工作区有未提交改动 | 测试构建 |
| 2026-08-21 | `1.0.0+4` | iOS 无签名归档 | `flutter build ipa --release --no-codesign` 成功 | Windows 同步目录，commit 未记录 | 编译验证 |
| 2026-08-21 | `1.0.0+4` | iPhone 15 Pro 开发签名 | 安装并启动成功 | Windows 同步目录，commit 未记录 | 真机测试 |
| 2026-08-22 | `1.0.0+4` | Flutter Web Release | 本地 `/app/` 基路径构建成功，未部署 | `e772d05` | 编译验证 |
| 2026-08-22 | 不适用 | 计划内容服务部署包 | 搜索修复已部署到生产 API 并通过复验 | `6d8821a` | 生产部署 |
| 2026-08-22 | `1.0.0+4` | iOS 无签名 Release App | 最新代码编译成功；签名构建受钥匙串权限阻塞 | `c31b384` | 编译验证 |
| 2026-08-22 | `1.0.0+4` | iPhone 15 开发签名 Release | 签名验证、安装和启动成功；名称搜索专项通过 | `c31b384` | 真机专项测试 |

2026-08-22 Web 验证使用 Flutter 3.44.4，产物位于本机忽略目录 `build/web/`；`flutter_bootstrap.js` SHA-256 为 `291DCB4473B0367873D480198B09B62FBD197577ADEC1AD3C1CD51B25668893B`。已检查模板占位符替换、JavaScript 语法、`/app/` 基路径和本地 CanvasKit 配置；未做线上浏览器或真机网络验收。

计划内容服务生产包为 `outputs/release-20260822-plan-search/caimaster-plan-content-20260822-161132.tar.gz`，大小 56,489 字节，SHA-256 为 `6820acd18905fc8c7fafeeB197fbe2a4b87708e9ff007bc111408528f731b562`。服务器端校验和、Shell 语法和 9 项相关测试通过后安装；生产 API 重启成功。`verify_plan_release.py --require-data` 总验收退出码为 0，部署检查、来源同步 dry-run、公开接口冒烟和严格数据冒烟均通过。外部复验确认不存在名称为 0 条、近期与历史分离、指定 ID 只返回对应计划。部署前备份为 `/opt/caimaster-api/backups/plan-search-20260822-160921.tar.gz`，SHA-256 为 `df284de63f153647749b4de525a7d98117e713c02481e86920a039725e0864e8`。`160040`、`160105` 和 `161044` 均为部署前候选，不得再次使用。

最新 iOS 编译目录为 `/Users/drop/Documents/Codex/2026-08-22/jingqiujing-c31b384`。无签名 `Runner.app` 构建成功，主可执行文件 SHA-256 为 `c69f0f79bf4b3853070985a7db2a7bc1442c840eedde09e01d815f6dcac519ee`。SSH 签名最初在 `Flutter.framework` 和 `objective_c.framework` 处因 `errSecInternalComponent` 失败；用户在 Mac 前台授权钥匙串后重新构建成功，随后签名验证、设备安装、启动及计划名称搜索专项均通过。该构建未归档、未上传 TestFlight。

## 新记录必填

- 构建日期和时区。
- 版本号与构建号。
- 平台、构建模式和签名类型。
- 来源 commit；工作区不干净时同时记录差异说明，并标记为测试构建。
- 产物文件名、SHA-256、保存位置或部署目标。
- 执行过的静态检查、测试和真机/浏览器验收。
- App Store、TestFlight 或公开下载状态必须单独记录，不能由“构建成功”推导。
