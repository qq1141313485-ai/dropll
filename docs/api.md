# 接口契约

这份文档只描述前端需要的最小接口，目的是让前后端不要反复对口径。

## 认证

所有接口都使用：

```http
Authorization: Bearer <private-app-token>
```

## 比赛列表

`GET /v1/matches?scope=today|finished&date=2026-07-04&limit=150`

返回字段建议：

- `id`
- `number`
- `league`
- `home`
- `away`
- `kickoff`
- `status`
- `score`
- `halfTimeScore`
- `odds`

其中 `odds` 里保留：

- `had`：胜平负
- `hhad`：让球胜平负
- `ttg`：总进球
- `crs`：比分
- `hafu`：半全场

## 单场详情

`GET /v1/matches/{official_match_id}`

返回单场比赛的完整赔率、比分和状态，前端详情页直接按这个结构渲染。

## 模型预测

`GET /v1/matches/{official_match_id}/predictions`

返回模型名称、方向、比分、命中状态、冷热标签和历史表现。

## 模型排行

`GET /v1/models/rankings?window=20`

返回最近窗口内的命中情况和样本数，给排行页和连黑榜使用。

## 刷新建议

- 首页列表：15 到 30 秒刷新一次
- 单场详情：10 到 30 秒刷新一次
- 后台抓取：按比赛状态和停售状态控制频率
