# 私有 API 约定

所有接口只返回数据，不提供购彩、代购或出票能力。请求使用：

```http
Authorization: Bearer <private-app-token>
```

## 比赛列表

`GET /v1/matches?scope=today|finished&date=2026-07-04`

返回比赛编号、联赛、主客队、开赛时间、状态、比分，以及官方赔率。

## 单场详情

`GET /v1/matches/{official_match_id}`

返回完整赔率、半场比分、全场比分和官方开奖结果。

## 模型观点

`GET /v1/matches/{official_match_id}/predictions`

返回模型名称、方向、预测比分、胜平负概率、冷热标签和赛后结算状态。

## 历史表现

`GET /v1/models/rankings?window=20`

返回固定窗口内的方向命中率、比分命中率和样本数。

## 刷新建议

- 首页比赛列表：20 到 30 秒刷新一次
- 单场详情：10 到 20 秒刷新一次
- 后台抓取：按停售、开赛和完场状态调整频率
