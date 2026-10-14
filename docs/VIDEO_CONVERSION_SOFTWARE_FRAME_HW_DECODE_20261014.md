# 保留 VideoToolbox / D3D11VA 硬件解码

日期：2026-10-14。

## 行为

硬件解码是否可用，与解码帧能否直接进入 GPU 缩放滤镜分开判断。新增 `hw_decode` 路径：硬件解码 → 软件帧固定尺寸 scale / setsar → 硬件编码。此路径保留 FFmpeg 默认 autoscale。

仅对配置含 `-hwaccel videotoolbox` 或 `-hwaccel d3d11va`，且没有指定硬件输出帧格式的情况启用。显式输出 GPU 帧的配置不能进入软件 scale；VAAPI、CUDA、QSV 的全硬件及 CPU 解码回退逻辑保持原有规则。旋转和未知尺寸可以使用这两个后端的软件帧路径，由 FFmpeg 自动旋转及默认 autoscale 处理。

回退顺序为 `hw_decode` → `hw_encode` → `cpu`；每次失败沿用原有临时文件清理及原因日志。停止、产出验证失败、替换提交失败均不触发重新转码。FFmpeg 自身可能对不支持的解码格式退回软件解码，因此模式名称表示尝试的路径，不保证所有输入均实际硬件解码。

## 验证

- 相关 Node 测试共 29 项：28 通过、1 因本机缺少 libwebp 跳过。覆盖两个后端的输入参数、软件滤镜、autoscale、旋转、未知尺寸、GPU 帧排除、关闭硬件加速及两级失败回退。
- 本机 FFmpeg 9.0.1 / VideoToolbox 实测：使用生产 helper 构建参数，将 320×180 H.264 输入缩放至 640×360，分别输出 H.264 和 HEVC，每个输出 50 帧。日志确认选择 `videotoolbox_vld`，编码使用 `-allow_sw 0` 禁止软件编码回退。硬件访问测试在沙箱外执行；临时生成的视频已删除。
- D3D11VA 尚无 Windows 硬件实测，当前覆盖路径与参数回归测试。

## 交付范围

本次仅更新服务端，无客户端改动，APK 仍为 2052。用户随后授权部署，已热更新远端两个生产文件，未重启容器；新启动的 Worker 加载新代码。

远端验证：10 项硬件路径单元测试全部通过；生产 Worker 的 VAAPI H.264/HEVC 原尺寸与 240p 裁剪、此前失败片段、可变尺寸逐帧检查、强制解码失败后的硬件编码回退、旋转与临时源文件安全替换均通过。内外健康接口返回成功。远端 Linux 不具备 VideoToolbox / D3D11VA 实测条件。

发布镜像：`nascabos-custom:video-decode-20261014`；旧镜像 `nascabos-custom:video-trim-fixed-20261014` 保留。部署目录 `/home/ermao/nascabos-video-release-decode-20261014/`，生产文件备份后缀 `.backup-decode-20261014`。

镜像无暂停提交，ID `sha256:9d492e20bc1a32c27fc9cdbe940b4072e2eb2f33ff55de2935410b1a1424239e`，同时更新 `nascabos-custom:latest`。归档 `/home/ermao/appdata/myimage/nascabos-custom-video-decode-20261014.tar.gz`（约 2.7 GiB），gzip 完整性校验通过，SHA-256 `5bd336ce7b3a53af67bb8151935700cf7ab2ccc4b5a2e640dbd6e9c950b03749`。

部署文件 SHA-256：

- `videoTransHardware.js`: `cb10885735dfce96060f58dc137a9d62f155b59f3337ee633bf28723216bbaa8`
- `videoTransWorker.js`: `1f150739f4afdc82d1844caaf7d6032efea21512705986d88ba2c6a1179072f2`

FFmpeg 5.1.9 中未设置输出格式的这两个后端使用默认帧下载行为，参见 [选项解析](https://github.com/FFmpeg/FFmpeg/blob/n5.1.9/fftools/ffmpeg_opt.c) 与 [硬件帧取回](https://github.com/FFmpeg/FFmpeg/blob/n5.1.9/fftools/ffmpeg_hw.c)。
