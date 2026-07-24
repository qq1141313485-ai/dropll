# 私有 API 约定

所有接口只返回数据，不提供购彩、代购或出票能力。

设备首次激活时请求：

```http
POST /v1/auth/enroll
Content-Type: application/json

{"enrollmentCode":"<device-activation-code>","deviceName":"iOS iPhone"}
```

服务器返回 15 分钟有效的 `accessToken` 与轮换的 `refreshToken`；刷新凭据仅由 App 存在 iOS Keychain。后续数据请求使用：

```http
Authorization: Bearer <short-lived-access-token>
```

`POST /v1/auth/refresh` 使用 `refreshToken` 换取新的访问凭据。激活与刷新接口按来源限流；服务端可通过凭据库撤销单台设备。

## 比赛列表

`GET /v1/matches?scope=today|finished&date=2026-07-04`

返回比赛编号、联赛、主客队、开赛时间、状态、比分，以及官方赔率。

## 单场详情

`GET /v1/matches/{official_match_id}`

返回完整赔率、半场比分、全场比分和官方开奖结果。

## 历史赔率

`GET /v1/matches/{official_match_id}/odds-history?limit=300`

按时间正序返回官方 SP 快照。后台每 30 秒检查一次官方赔率，只有胜平负、让球胜平负、总进球、比分或半全场任一玩法实际变化时才新增记录。每项包含 `capturedAt` 和 `odds`；历史从 2026-07-23 开始积累，不能补回此前未保存的走势。

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
