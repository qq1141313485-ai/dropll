# 字段映射表

这份文档的作用很简单：后面改数据时，不用再反复问“这个字段前端显示到哪里”。

## matches

| 数据库字段 | 接口字段 | 前端展示 |
| --- | --- | --- |
| `official_match_id` | `id` | 比赛唯一 ID |
| `number` | `number` | 周几加场次编号 |
| `league` | `league` | 联赛名 |
| `home` | `home` | 主队 |
| `away` | `away` | 客队 |
| `kickoff` | `kickoff` | 开赛时间 |
| `status` | `status` | `PENDING` / `LIVE` / `FINISHED` |
| `score` | `score` | 当前比分 |
| `half_time_score` | `halfTimeScore` | 半场比分 |
| `final_score` | `finalScore` | 完场比分 |
| `spf_sp_json` | `odds.had` | 胜平负 SP |
| `handicap_spf_sp_json` | `odds.hhad` | 让球胜平负 SP |
| `total_goals_sp_json` | `odds.ttg` | 总进球 SP |
| `score_sp_json` | `odds.crs` | 比分 SP |
| `half_full_sp_json` | `odds.hafu` | 半全场 SP |

## ai_predictions

| 数据库字段 | 接口字段 | 前端展示 |
| --- | --- | --- |
| `match_id` | `matchId` | 关联比赛 |
| `model_name` | `model` | 模型名称 |
| `predict_direction` | `direction` | 胜平负或总进球方向 |
| `predict_score` | `score` | 预测比分 |
| `instant_sp_json` | `instantSp` | 命中时使用的即时 SP 值 |
| `is_hit` | `isHit` | 是否命中 |
| `current_black_streak` | `blackStreak` | 当前连黑场数 |
| `current_red_streak` | `redStreak` | 当前连红场数 |

## 展示约定

- 即时页只展示 `today` 的比赛。
- 完场页只展示 `finished` 的比赛。
- 赔率默认优先显示官方 SP，不展示无关字段。
- 模型页默认优先展示命中状态和方向，不展开长解释。
