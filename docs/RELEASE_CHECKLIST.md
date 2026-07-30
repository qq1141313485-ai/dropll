# iOS 上架清单

本清单用于 App Store 提交前核对。未完成的阻塞项不应通过说明文字掩盖。

## 阻塞项

- [x] 生产 API 已迁移为 HTTPS 域名，并移除 iOS 的任意 HTTP 加载例外。
- [x] 客户端不携带 API Token；公开只读接口通过 HTTPS、Nginx 限流和只读数据库连接保护。
- [x] 隐私政策内容已与服务器最长 30 天日志保留策略一致，并上线公开 URL：`https://api.cclloo.com/privacy`。
- [x] Support 页面已上线：`https://api.cclloo.com/support`；提交前仍需在 App Store Connect 填入该 URL 和开发者联系信息。
- [ ] 逐地区确认赛事数据、彩票相关计算与营销文案的合规边界；不提供出票、代购、投注或资金服务。
- [x] 服务中心已移除交流群和门店导流，仅保留使用帮助、数据反馈与内容投诉/下架申请。
- [ ] 按 [计划内容授权与权利证明](CONTENT_RIGHTS_EVIDENCE.md) 整理转载授权，
  并保存可供 App Review 核验的授权范围和期限。
- [ ] 连续验证实时比分、完场赛果和已保存方案结算，不允许出现错误比分、长期卡住或空白列表。
- [ ] 完成 [连续 7 天数据稳定性验收](SEVEN_DAY_STABILITY_ACCEPTANCE.md)；
  已于 2026-07-29 开始记录。
- [x] 计划内容服务已通过 `deploy_plan_content_remote.sh --patch-api-app` 部署。
- [x] 计划内容服务部署检查通过：`verify_plan_release.py --base-url https://api.cclloo.com --require-data`。

## 提交资料

- [x] 已准备 [App Store 简体中文文案](APP_STORE_METADATA_ZH_CN.md)，包含
  版本号、构建号、“最新功能”、描述、关键词和审核备注草稿。
- [ ] 1024 x 1024 App 图标、真实 iPhone 截图、分类与年龄分级。
- [ ] App Privacy 问卷，内容必须与 [隐私政策](PRIVACY_POLICY.md) 一致。
- [x] iOS Privacy Manifest 已加入 Runner，声明不追踪，并登记 UserDefaults 所需原因 API。
- [x] App Review Notes 草稿已说明不提供彩票销售、代购、投注或资金服务，
  并列出数据依赖与测试路径；提交前按最终版本复核。

## 真机回归

- [ ] 按 [iOS 真机发布回归](IOS_DEVICE_REGRESSION.md) 完成 TestFlight 发布构建验收。
- [ ] 冷启动、后台恢复、弱网、断网和接口超时。
- [ ] 首页、赛果、详情、选号、保存方案、结算和分享。
- [ ] 计划 Tab、全部计划、计划详情、图片浏览和搜索。
- [ ] 隐私政策、问题反馈和外部链接。
- [x] 首版限定 iPhone 竖屏；iPad 适配留待后续版本。
