# 计划内容服务

本文只维护计划内容服务的代码结构、打包、安装和部署方式。业务规则、名称治理、
授权边界和运行验收以 `docs/PLAN_SOURCE_SYNC.md`、
`docs/CONTENT_RIGHTS_EVIDENCE.md` 为准。

线上路径：

- `plans.py` -> `/opt/caimaster-api/plans.py`
- `plan_admin.html` -> `/opt/caimaster-api/plan_admin.html`
- `deploy_check.py` -> `/opt/caimaster-api/deploy_check.py`
- `app_plan_smoke.py` -> `/opt/caimaster-api/app_plan_smoke.py`
- `manage_api_env.py` -> `/opt/caimaster-api/manage_api_env.py`
- `patch_api_app.py` -> 自动给主 FastAPI 入口安装计划路由
- `verify_plan_release.py` -> 上线前总验收脚本
- `deploy_plan_content_remote.sh` -> 本地打包、上传、远程安装和验收脚本
- `install_plan_content.sh` -> 服务器端安装/更新脚本
- `package_plan_content.sh` -> 生成服务器上传包

主 API 的 `app.py` 需要在创建 FastAPI 实例后安装计划路由：

```python
from plans import install_plan_routes

install_plan_routes(app)
```

`deploy_check.py` 会静态检查 `/opt/caimaster-api/app.py` 中是否包含
`install_plan_routes`，避免忘记把路由挂到主 API。
也可以先预览自动接入：

```bash
cd /opt/caimaster-api
python3 patch_api_app.py --app /opt/caimaster-api/app.py --dry-run
```

运行依赖见 `requirements.txt`。管理员密钥仅配置在服务器环境变量 `CAIMASTER_PLAN_ADMIN_TOKEN`，不得提交到 Git。

上线前先生成上传包：

```bash
cd server/plan_content
./package_plan_content.sh
```

如果本机已配置 SSH 登录服务器，可以直接执行远程部署：

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

脚本会本地打包、校验 checksum、上传到服务器、远程安装、重启
`caimaster-api.service`，最后运行 `verify_plan_release.py`。正式已有计划图片后，
追加 `--require-data`。真实部署必须加 `--yes`；如果当前 SSH 用户就是 root，可不加 `--sudo`。

把 `dist/caimaster-plan-content-*.tar.gz` 和 `.sha256` 上传到服务器，校验后解包：

```bash
shasum -a 256 -c caimaster-plan-content-*.tar.gz.sha256
tar -xzf caimaster-plan-content-*.tar.gz
cd caimaster-plan-content-*
./install_plan_content.sh --skip-dry-run
```

如果确认主入口是 `/opt/caimaster-api/app.py`，可让安装脚本自动接入计划路由：

```bash
./install_plan_content.sh --patch-api-app --skip-dry-run
```

如果已经直接上传了 `server/plan_content/` 目录，也可以执行：

```bash
cd server/plan_content
./install_plan_content.sh --skip-dry-run
```

脚本会复制文件、备份旧文件、创建缺失的 `api.env` 和 `plan_source_map.json` 模板、
自动生成管理员密钥、安装 systemd unit、运行 Python 编译检查和 `deploy_check.py`。
加 `--patch-api-app` 时，会先备份 `app.py`，再插入 `from plans import install_plan_routes`
和 `install_plan_routes(app)`；如果已接入则不重复修改。
可查看掩码后的配置：

```bash
cd /opt/caimaster-api
python3 manage_api_env.py show
```

`show` 只显示掩码密钥。需要轮换密钥时执行：

```bash
python3 manage_api_env.py set-token
```

如果需要完全手工管理 `api.env`，安装时加 `--no-env-init`。

配置完成后执行：

```bash
cd /opt/caimaster-api
python3 verify_plan_release.py --base-url https://api.cclloo.com
```

`verify_plan_release.py` 会加载同目录 `api.env`，依次运行 `deploy_check.py`、来源同步 dry-run
和 App 公开接口 smoke。确认检查通过后再重启 `caimaster-api.service`。
单项排查时仍可分别执行 `deploy_check.py --json`、
`CAIMASTER_PLAN_SOURCE_DRY_RUN=1 python3 plan_source_sync.py` 和
`python3 app_plan_smoke.py --base-url https://api.cclloo.com`。
需要启用同步 timer 时执行：

```bash
./install_plan_content.sh --enable-timer
```

正式上传计划内容后，可用严格模式验收 App 所需字段：

```bash
python3 verify_plan_release.py --base-url https://api.cclloo.com --require-data
```

本目录脚本测试：

```bash
python3 -m unittest test_plan_source_sync.py test_app_plan_smoke.py test_deploy_check.py test_manage_api_env.py test_patch_api_app.py test_verify_plan_release.py
```

本地模拟安装演练：

```bash
rm -rf /tmp/caimaster_plan_deploy_smoke
./install_plan_content.sh \
  --target /tmp/caimaster_plan_deploy_smoke \
  --python /usr/bin/python3 \
  --skip-deploy-check \
  --skip-dry-run
```
