# 计划内容管理

计划内容使用独立数据库和图片目录，不写入赛事数据库。

## 管理入口

- 地址：`https://api.cclloo.com/admin/plans`
- 管理员密钥保存在服务器 `/opt/caimaster-api/api.env`
- 密钥不得写入 App、Git、截图或交接文档

管理页面支持：

- 新建计划
- 为计划批量上传图片
- 指定批次名称和发布时间
- 下架或恢复整个计划
- 查看并处理自动同步产生的待治理计划名称
- 查看自动同步状态摘要和最近运行记录
- 查看自动同步健康检查结果
- 将失败文章加入下一轮自动同步重试队列

正式图片上传后，App 会优先显示服务器数据；服务器尚无正式图片时继续显示内置演示内容。

## 服务器文件

- 接口模块：`/opt/caimaster-api/plans.py`
- 管理页面：`/opt/caimaster-api/plan_admin.html`
- 计划数据库：`/opt/caimaster-api/plans.db`
- 图片目录：`/opt/caimaster-api/plan-media`

图片上传后会保存原图和缩略图。首页、全部计划和更新批次使用缩略图，进入图片浏览后再加载原图。

## 公开接口

- `GET /v1/plans`
- `GET /v1/plans/recent`
- `GET /v1/plans/{plan_id}/updates`
- `GET /media/plans/{filename}`

## 下架规则

- 计划下架后，公开列表和搜索不再返回。
- 更新批次下架后，公开详情不再返回。
- 文件不会自动删除，便于误操作后恢复。
