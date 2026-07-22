# 数据库说明

数据库使用 SQLite，本地文件优先，适合轻量部署和快速调试。

## matches

存储比赛主数据和实时状态。

建议字段：

- `id`
- `official_match_id`
- `number`
- `league`
- `home`
- `away`
- `kickoff`
- `status`
- `score`
- `half_time_score`
- `final_score`
- `spf_sp_json`
- `handicap_spf_sp_json`
- `total_goals_sp_json`
- `score_sp_json`
- `half_full_sp_json`
- `updated_at`

## ai_predictions

存储模型分析结果和赛后结算状态。

建议字段：

- `id`
- `match_id`
- `model_name`
- `predict_direction`
- `predict_score`
- `instant_sp_json`
- `is_hit`
- `current_black_streak`
- `current_red_streak`
- `created_at`
- `updated_at`

## 设计原则

- 赔率字段保留 JSON，避免频繁改表。
- 比赛主数据和模型结果分表，避免互相污染。
- 状态字段尽量只用固定枚举值。
- 能用 `INSERT OR IGNORE` 的地方尽量用，减少重复数据。
