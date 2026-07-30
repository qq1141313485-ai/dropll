# 计划内容接入 App 验收

## 服务器

1. 本机已配置 SSH 时，推荐直接远程部署：

```bash
cd server/plan_content
./deploy_plan_content_remote.sh \
  --host user@server \
  --sudo \
  --patch-api-app \
  --base-url https://api.cclloo.com \
  --dry-run

./deploy_plan_content_remote.sh \
  --host user@server \
  --sudo \
  --patch-api-app \
  --base-url https://api.cclloo.com \
  --yes
```

正式已有计划图片后，追加 `--require-data`。真实部署必须加 `--yes`；如果 SSH 用户就是 root，可不加 `--sudo`。

2. 也可以手工生成并上传计划内容服务包：

```bash
cd server/plan_content
./package_plan_content.sh
```

3. 在服务器上校验并安装：

```bash
shasum -a 256 -c caimaster-plan-content-*.tar.gz.sha256
tar -xzf caimaster-plan-content-*.tar.gz
cd caimaster-plan-content-*
./install_plan_content.sh --skip-dry-run
```

首次接入主 API 时，如果入口文件是 `/opt/caimaster-api/app.py`，可改用：

```bash
./install_plan_content.sh --patch-api-app --skip-dry-run
```

安装脚本会自动生成正式 `CAIMASTER_PLAN_ADMIN_TOKEN`，可用 `python3 manage_api_env.py show`
查看掩码后的配置。

4. 运行上线检查：

```bash
cd /opt/caimaster-api
python3 verify_plan_release.py --base-url https://api.cclloo.com
```

5. 重启 API 服务后，打开 `https://api.cclloo.com/admin/plans`，确认能登录、健康检查无 error。

## 公开 API

未上传正式图片前，App 会回退内置演示数据。上传至少一个计划批次后运行：

```bash
python3 verify_plan_release.py --base-url https://api.cclloo.com --require-data
```

必须通过的接口：

- `GET /v1/plans/recent`
- `GET /v1/plans`
- `GET /v1/plans/{plan_id}/updates`
- `GET /media/plans/{filename}`

## App

默认 API 地址为 `https://api.cclloo.com`。如需指定环境：

```bash
flutter run --dart-define=CAIMASTER_API_BASE_URL=https://api.cclloo.com
```

验收点：

- 底部导航出现“计划”。
- 计划首页显示“已连接服务器数据”；若显示“当前显示演示数据”，先排查 API 部署、路由接入和图片数据。
- “最近更新”展示服务器计划。
- 进入详情能看到更新批次和缩略图。
- 点开图片能加载原图。
- 搜索计划名称能返回服务器数据。
- 断网或服务器无计划时仍显示内置演示数据，不阻塞首页比分。
