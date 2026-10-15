# MetaTube 文件名标签合入类型筛选（2026-10-15）

用户明确授权部署至 `ermao@ddns.ermao.fun:13122`，并同步现有电影 NFO 和筛选索引，不触发刮削。

## 生效行为

“中文字幕”“破解版本”保留在 NFO `<tag>` 中供电影卡片角标使用，同时加入 `<genre>`，复用客户端详情页的可点击类型标签、电影列表类型筛选和智能专辑类型条件。番号、来源、厂商等其他 `<tag>` 不混入类型。原有类型保留并去重。

MetaTube 自动和手动刮削共用的写入入口在翻译后合入这两个类型，避免翻译改变筛选名称。本次没有启动刮削任务。

## 服务端与存量回填

部署文件：

- `src/workers/videoIndex/nfoFetchWorker/metatubeFilenameTags.js`
- `src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
- `scripts/refreshMovieNfoFilenameTags.js`

临时验证目录 `/tmp/nfo-genre-merge-20261015` 中另包含既有 NFO 解析器，不覆盖线上解析器。原服务端文件、SQLite 数据库、待修改原始 NFO 及 manifest 备份于容器 `/nascabos_data/backups/nfo-genre-merge-20261015/`，映射用户数据挂载卷。

回填检查 941 部电影，226 份 NFO 更新，693 条索引同步或补齐类型检索记录，24 部无 NFO 跳过，无无效 NFO 或错误。再次 dry-run 的 NFO 和索引变更均为 0。`nfo_get_state` 与回填前数据库备份对照无变化。

没有重启容器或 API Worker；现有 API 已支持读取 `nfo_genres` 和类型检索表。发布时没有活动的 NFO 获取进程，后续新进程直接读取新策略。

## 验证

31 项 Node 回归测试通过；本机使用 Electron 匹配的 SQLite 运行时完成独立临时库维护验证：保留标题和剧情，补齐双类型和三个检索记录，不改刮削状态，重复 dry-run 无变更。

远端实际只读调用现有 `VideoListService._getFilterOptions`，确认两种标签均出现在筛选选项中。使用同一查询结构检查全部命中结果：

| 类型条件 | 电影数 | 类型字段不符合条件的结果 |
| --- | ---: | ---: |
| 中文字幕 | 221 | 0 |
| 破解版本 | 11 | 0 |
| 同时选择两者 | 6 | 0 |

验证通过只读数据库和筛选服务完成，未读取会话凭据或发起刮削。

无需重新打包客户端，刷新电影列表或重新进入详情页即可使用这些标签。

## 镜像与归档

镜像 `nascabos-custom:metatube-genre-merge-20261015` 已无暂停提交，同时更新 `nascabos-custom:latest`。镜像 ID：`sha256:8e252386cdab92bc6d41383306878178b0bdede9a9ab58721d0e634ec3789383`。

归档 `/home/ermao/appdata/myimage/nascabos-custom-metatube-genre-merge-20261015.tar.gz`，约 2.8 GiB；`gzip -t` 通过，SHA-256 `deb733fd87f3d6d023e6746a878bc5df8bade2494694b33ac8b60bbaea72c98a`，校验文件存于同目录 `.sha256`。最终健康检查 HTTP 200，三个部署文件 SHA-256 两端一致。
