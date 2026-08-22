# 计划图片自动同步

同步器只可处理已完成授权核验的公开站点内容，并保存来源站已经提供的水印图片，
不移除或遮挡来源水印。当前授权证据是否完整以
`CONTENT_RIGHTS_EVIDENCE.md` 为准；授权范围未确认前，不得把技术上可抓取描述为
已获授权，也不得据此提交上架说明。

本文负责同步规则、名称治理和运行验收；安装与打包命令以
`server/plan_content/README.md` 为准，避免维护两套部署流程。

## 文件

- `/opt/caimaster-api/plan_source_sync.py`
- `/opt/caimaster-api/deploy_check.py`
- `/opt/caimaster-api/app_plan_smoke.py`
- `/opt/caimaster-api/install_plan_content.sh`
- `/opt/caimaster-api/patch_api_app.py`
- `/opt/caimaster-api/verify_plan_release.py`
- 本地 `server/plan_content/deploy_plan_content_remote.sh`
- `/opt/caimaster-api/plan_source_map.json`
- `/opt/caimaster-api/api.env`
- `/etc/systemd/system/caimaster-plan-source-sync.service`
- `/etc/systemd/system/caimaster-plan-source-sync.timer`

## 工作方式

1. 每五分钟读取公开文章列表。
2. 只处理最近两天且标题以日期开头的文章，例如 `20260725公牛`。
3. 读取文章详情中的全部图片。
4. 按来源文章 ID、图片 URL 和 SHA-256 内容哈希去重。
5. 按名称治理规则匹配计划名称，创建当天更新批次，生成 App 使用的原图与缩略图。
6. 已在后台配置过名称规则或手动重试的文章会进入重跑队列，不依赖来源列表分页是否还能扫到。
7. 每次运行会写入同步批次记录，后台可查看最近运行状态、候选数量和各类计数。
8. 采集失败只写日志，不影响赛事 API；管理页仍可纠错或下架。

标题不能准确对应计划时，在 `plan_source_map.json` 中配置名称治理规则。配置格式见
`plan_source_map.example.json`：

- `allowedNames`：允许自动入库的标准计划名称。
- `aliases`：来源标题名到标准计划名的映射。
- `imageAssignments`：仅用于人工逐图确认后的、可审计的历史修复或一次性导入。
  该字段虽然仍为兼容旧数据保留，但不得根据文章标题顺序、图片数量或每日位置
  自动生成日常归属。配置项数量必须与来源文章图片数量完全一致；不一致或逐图
  证据不足时继续保持待治理状态，不会导入或猜测。
- `ignoredNames`：确认不是计划内容的标题名。
- `excludedTitleWords`：标题中包含这些词时直接忽略。
- `allowAutoCreate`：为 `false` 时，未在规则中的名称会进入 `pending_name` 待治理状态，不会自动建计划。

当来源名称本身不在允许名单中，但去掉“早、晚、早场、晚场、早单、晚单、上午场、
下午场、夜场”后得到的主体名称明确存在于 `allowedNames` 时，同步器会自动归并到
主体计划。显式 `aliases` 和完整允许名称优先，不会覆盖人工配置，也不会为陌生主体
自动建计划。

旧版 `{ "来源名": "标准名" }` 映射仍可读取，并保持自动创建兼容。正式运行建议使用结构化格式，
把 `allowAutoCreate` 设为 `false`。一篇文章标题包含多个计划、但图片本身无法区分时，不要猜测拆分，应在管理后台纠正。

## 环境变量

在 `/opt/caimaster-api/api.env` 中配置：

```text
CAIMASTER_PLAN_SOURCE_ENABLED=1
CAIMASTER_PLAN_SOURCE_MAX_PAGES=30
CAIMASTER_PLAN_SOURCE_LOOKBACK_DAYS=2
CAIMASTER_PLAN_SOURCE_QUEUED_RETRY_LIMIT=100
CAIMASTER_PLAN_SOURCE_DRY_RUN=0
CAIMASTER_PLAN_SOURCE_MAP=/opt/caimaster-api/plan_source_map.json
```

## 部署与验证

打包、远程部署、手工安装、路由接入和密钥初始化的唯一操作说明位于
`server/plan_content/README.md`。任何线上修改仍须先创建时间戳备份。

部署完成后在服务器执行总验收：

```bash
cd /opt/caimaster-api
python3 verify_plan_release.py --base-url https://api.cclloo.com
systemctl daemon-reload
journalctl -u caimaster-plan-source-sync.service -n 120 --no-pager
```

`verify_plan_release.py` 会加载 `/opt/caimaster-api/api.env`，依次运行部署检查、来源同步 dry-run
和 App 公开接口 smoke。`deploy_check.py` 会检查 Python 依赖、管理员密钥、主 `app.py` 是否已安装计划路由、规则文件、媒体目录、数据库表、
管理页、systemd 文件、待治理名称、失败文章、重试队列和最近一次同步运行。需要给运维系统读取时
可加 `--json`。`CAIMASTER_PLAN_SOURCE_DRY_RUN=1` 会读取来源列表、解析标题、读取详情并检查图片 URL，
但不会写数据库或图片文件。正式启用后检查 `/v1/plans/recent` 和管理页，再决定是否保留自动创建的计划名称。
`app_plan_smoke.py` 会按 App 使用方式检查 `/v1/plans/recent`、`/v1/plans` 和
`/v1/plans/{id}/updates` 的字段。正式上传计划图片后，对总验收脚本加 `--require-data` 可要求线上必须有可展示数据。

同步 timer 的安装与启用命令同样以服务 README 为准。只有 dry-run、后台健康检查、
公开接口 smoke 和内容授权范围均确认后，才可启用正式同步。

## 名称治理排查

管理页的“待治理名称”来自 `plan_sync_articles.status = 'pending_name'`。
新增名称后，可以直接在管理页选择现有计划或填写标准名称并保存规则；后台会写入
`plan_source_map.json`。保存规则后，该条同步记录会变成 `name_configured`，下一次同步
会从重跑队列重新处理。确认不是计划内容时点“忽略”，记录会变成 `ignored` 并跳过后续同步。
失败文章可以在管理页点“重试”或“全部重试”，记录会变成 `retry_queued`，下一次同步会重新处理。

也可以手动编辑规则文件：把标准名加入 `allowedNames`，或把来源别名加入 `aliases`，
再重新运行同步服务。

也可以直接调用后台接口查看：

```bash
curl -H "Authorization: Bearer $CAIMASTER_PLAN_ADMIN_TOKEN" \
  "https://api.cclloo.com/v1/admin/plan-sync/articles?status=pending_name&limit=80"
```

后台规则接口：

- `GET /v1/admin/plan-sync/health`
- `GET /v1/admin/plan-sync/summary`
- `GET /v1/admin/plan-sync/runs`
- `POST /v1/admin/plan-sync/articles/retry`
- `GET /v1/admin/plan-sync/name-rules`
- `PUT /v1/admin/plan-sync/name-rules`
- `POST /v1/admin/plan-sync/name-rules/actions`
