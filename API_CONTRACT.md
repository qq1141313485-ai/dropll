# 公开只读 API 约定

所有接口只返回公开赛事、赔率和模型展示数据，不提供购彩、代购、出票、账户资金或用户资料服务。App 打开即可使用，不要求注册或登录。

服务器通过 HTTPS、Nginx 限流和只读数据库连接保护数据服务；客户端不携带 API Token。

## 比赛列表

`GET /v1/matches?scope=today|finished&date=2026-07-04`

返回比赛编号、联赛、主客队、开赛时间、状态、比分，以及官方赔率。

## 单场详情

`GET /v1/matches/{official_match_id}`

返回完整赔率、半场比分、全场比分和官方开奖结果。

## 历史赔率

`GET /v1/matches/{official_match_id}/odds-history?limit=300`

按时间正序返回官方 SP 快照。后台每 30 秒检查一次官方赔率，只有胜平负、让球胜平负、总进球、比分或半全场任一玩法实际变化时才新增记录。每项包含 `capturedAt` 和 `odds`；历史从 2026-07-23 开始积累，不能补回此前未保存的走势。

## 比赛分析

`GET /v1/matches/{official_match_id}/analysis`

返回竞彩网比赛 ID 对应的历史交锋、主客队积分数据，以及双方近期战绩。服务端
统一获取并缓存 6 小时；来源短暂失败时可以返回 7 天内最近一次成功缓存，并标记
`stale: true`。每个模块通过 `availability` 独立声明是否有真实数据，客户端必须
隐藏缺失模块，不能用演示数据补齐。

欧赔、亚赔和大小球不属于该接口。三类盘口后续使用独立、已授权的数据源，不能
用竞彩固定奖金模拟。

## 模型观点

`GET /v1/matches/{official_match_id}/predictions`

返回模型名称、方向、预测比分、胜平负概率、冷热标签和赛后结算状态。

## 历史表现

`GET /v1/models/rankings?window=20`

返回固定窗口内的方向命中率、比分命中率和样本数。

## 计划内容

`GET /v1/plans?limit=20&offset=0&q=单刀&activity=recent`

按最近更新时间倒序返回计划摘要、今日是否更新、最新图片数量和缩略图。`activity` 支持 `recent`（近 7 个自然日）、`history`（更早）和 `all`（默认，兼容旧版）。支持 `ids=2,3` 获取本机收藏的计划，单页最多 50 条；按 ID 查询时不限制活跃范围。

`GET /v1/plans/recent?limit=6`

返回最近更新的计划，每个计划只出现一次。

`GET /v1/plans/{plan_id}/updates?limit=10&offset=0&days=7`

分页返回计划的更新批次和图片。列表使用 `thumbnailUrl`，图片浏览与下载使用 `imageUrl`。已下架计划和更新不会出现在公开接口中。

## 刷新建议

- 首页比赛列表：20 到 30 秒刷新一次
- 单场详情：10 到 20 秒刷新一次
- 后台抓取：按停售、开赛和完场状态调整频率
- 计划首页：进入页面或用户主动刷新时获取
