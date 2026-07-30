# 比赛分析采集模块

该模块为主 API 增加：

`GET /v1/matches/{official_match_id}/analysis`

一期数据包括：

- 历史交锋
- 主、客队积分数据
- 主队近期战绩
- 客队近期战绩

数据由阿里云服务器统一获取并缓存，App 不直接访问第三方网站。缓存默认
6 小时；刷新失败时最多使用 7 天内的旧缓存，并返回 `stale: true`。

推荐使用安装脚本。默认只复制、备份、修补和检查，不重启服务：

```bash
./install_match_analysis.sh
./install_match_analysis.sh --restart --smoke-match 2040634
```

也可以在 `/opt/caimaster-api/app.py` 创建 FastAPI 实例后手动安装路由：

```python
from match_analysis import install_match_analysis_routes

install_match_analysis_routes(app)
```

部署前先备份线上 `app.py`，并把本目录的 `match_analysis.py` 和
`__init__.py` 复制到 `/opt/caimaster-api/match_analysis/`。

测试：

```bash
cd server/match_analysis
python3 -m unittest -v
```
