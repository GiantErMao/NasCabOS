# 视频裁剪硬件链路优化

后续可变分辨率保护已更新此策略，见 `VIDEO_CONVERSION_FIXED_GEOMETRY_20261014.md`；下文保留此前发布记录。

日期：2026-10-14。服务端更新，Web 和 APK 无需更换，设备现有 2052 版继续使用。

## 行为

- 硬件转码默认 `-noautoscale`。原分辨率不插入缩放器，避免过滤链重建时 FFmpeg 自动插入软件 `scale` 而无法读取 GPU 帧。
- 完整硬件链路调整分辨率时，按帧类型选择 `scale_vaapi`、`scale_cuda` 或 `scale_qsv`，保持硬件帧处理；这些选择中，本次远端实际验证的是 VAAPI。
- 尝试顺序：`hw_full`（硬件解码＋硬件编码）→ `hw_encode`（CPU 解码＋硬件编码）→ `cpu`（全 CPU）。没有可用完整硬件路径时从 `hw_encode` 开始；关闭硬件加速则只使用 CPU。
- 中间级不带硬件解码参数；需要时先软件缩放，再通过 `format=nv12,hwupload` 上传给 VAAPI/QSV 编码器。
- 停止任务及产出校验/源文件提交失败不会触发下一次尝试，避免停止后重跑或覆盖后再次裁剪。
- 每级失败都记录错误摘要和下一尝试级别；全部失败时汇总三个原因。

## 源码

- `electron_server/src/api/modules/mediaTool/videoTransHardware.js`：硬件滤镜计划和顺序回退。
- `electron_server/src/workers/mediaTool/videoTrans/videoTransWorker.js`：接入执行与回退日志。
- `electron_server/tests/videoTransHardware.test.js`：5 项硬件计划、回退和终止保护测试。

## 验证

本地 Node 相关测试：22 项，21 通过、1 跳过、0 失败。跳过项仍为本机缺少 WebP 编码器，WebP 已在此前远端发布验证过。语法、格式和 diff 检查通过。

远端隔离执行通过：

1. H.264 原分辨率与 240p 完整硬件裁剪。
2. H.265 原分辨率与 240p 完整硬件裁剪。
3. 此前触发帧格式转换错误的真实视频：读取 96–106 秒片段，现在通过 `hw_full` 产出并验证时长。仅短片段验证，未重裁整部视频，也未覆盖这份真实源文件。
4. 人为提供无效硬件解码设备，验证程序记录失败后使用 CPU 解码＋真实 VAAPI 编码成功，保留裁剪及 240p 设置。
5. 生成视频的完整输出校验和源路径替换。

## 上线

只上线 helper 和 Worker 两个服务端文件，helper 先安装、Worker 原子替换。没有重启容器；已启动 Worker 继续原执行策略，新启动任务加载优化。

- 旧 Worker：`/nascabos/src/workers/mediaTool/videoTrans/videoTransWorker.js.backup-hw-20261014`。
- 发布目录：`/home/ermao/nascabos-video-release-hw-20261014`。
- 生产文件与本地 SHA-256 一致：

```text
videoTransHardware.js: 27f6733d37cc564abf215ded1a1b1502c62f4774185e17039daa2defe475f25b
videoTransWorker.js: 35857051f932a01ac9f1d5cd1d8bd9e419bda4965b836489de716cf0f6a19d11
```

健康接口正常。上线后只读核对，原任务 3 和 4 均为 `stopped`，各处理成功 1 个视频、`last_error` 为空。没有自动重新运行它们。

镜像 ID：`sha256:98e8dc42eb943c76fe21e345386b90f30c2c3969d195fc42b20b0a2ab0a01466`。

镜像快照使用 `--no-pause`，避免暂停现有任务；数据库和媒体仍在挂载卷中，不属于代码镜像归档。

镜像标签：`nascabos-custom:video-trim-hw-20261014`，同时更新 `nascabos-custom:latest`。

归档：`/home/ermao/appdata/myimage/nascabos-custom-video-trim-hw-20261014.tar.gz`，已完成（约 2.7 GiB），`gzip -t` 完整性校验通过，并生成 `.sha256` 文件。

```text
SHA-256: 11d9c64d1ee8934ea0b69d1438241a56aefe7eccfabbee0144a0127dadb7c2ca
```
