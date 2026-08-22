# 数据库说明

本文维护当前数据库拓扑和表职责，不充当可直接执行的迁移脚本。修改线上结构前，
必须先只读导出实际 SQLite schema，并与创建/迁移代码核对；不得仅依据本文猜测列名。

## 数据库拓扑

| 数据库 | 主要职责 | 结构权威来源 |
| --- | --- | --- |
| 赛事主库 | 比赛、状态、实时比分、官方赛果、竞彩 SP、赔率快照及模型结果 | 线上实际 schema、赛事采集/API 代码 |
| `/opt/caimaster-api/plans.db` | 计划、更新、图片、别名、来源同步、OCR 结果与成本记录 | `server/plan_content/plans.py`、`plan_source_sync.py` |

## 赛事主库主要表

- `matches`：比赛主数据、实时状态、半场/完场比分、官方竞彩各玩法 SP 和更新时间。
- `odds_snapshots`：按内容变化保存的官方 SP 历史快照。
- `ai_predictions`：模型展示结果和赛后结算状态；是否继续作为用户可见功能，以
  当前代码和主交接文档为准，不能从早期 `spec.md` 推断。

赛事 API 字段以 `API_CONTRACT.md` 为准。线上表可能包含同步、绑定和动态分钟所需的
扩展列，任何迁移都必须先读取实际 schema。

## 计划内容库主要表

- `plans`：标准计划名称、slug、启用状态和时间。
- `plan_updates`：计划更新批次、发布时间和启用状态。
- `plan_images`：原图与缩略图文件名、排序、尺寸和启用状态；来源 URL 与内容哈希
  保存在 `plan_sync_images`。
- `plan_aliases`：旧计划 ID 到标准计划 ID 的迁移映射。
- `plan_sync_articles`：来源文章、识别状态、原始/解析名称和待复核状态。
- `plan_sync_images`：来源图片 URL 与内容哈希去重。
- `plan_sync_article_updates`：来源文章与一个或多个计划更新的关联。
- `plan_sync_runs`：同步批次、计数和错误。
- `plan_ocr_results`：按图片内容哈希缓存 OCR 结果。
- `plan_ocr_decisions`：候选、最终归属、置信度和人工复核状态。
- `plan_ocr_usage`：OCR 尝试时间和结果。当前结构没有独立金额字段；若启用收费 OCR，
  必须先补充可审计的调用量与成本记录，不能仅用该表推断真实费用。

## 结构纪律

- 赛事库与计划库保持隔离，计划写入不得影响赛事只读 API。
- 赔率 JSON、固定状态枚举、唯一键和外键约束以实际创建代码为准。
- 变更前备份数据库并记录旧、新 schema；变更后执行部署检查和公开接口 smoke。
- 文档不得保存数据库文件、用户资料、管理员密钥或其他敏感凭据。
