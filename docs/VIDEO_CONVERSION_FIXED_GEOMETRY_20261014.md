# 条件关闭 autoscale 与可变分辨率保护

日期：2026-10-14。此记录更新此前硬件优化中“所有硬件模式都关闭自动缩放”的策略。

## 修复

仅在**明确固定输出宽高且输出为 GPU 帧**时使用 `-noautoscale`，防止 FFmpeg 将 GPU 帧送进隐式软件 scale。

- 首帧探测：使用 ffprobe 读取源开头 1 秒内的首个解码视频帧；探测失败时回退到视频流元信息。单次探测 15 秒超时、4 MiB 输出上限。
- 固定画布：原分辨率固定到首帧尺寸；自定义分辨率只在开始时根据初始宽高计算目标尺寸，并对齐到偶数。两个维度都是明确数字，避免 `w=-2` 随每段输入宽高比重新变化。
- 稳定像素宽高比：显式设置初始 SAR；旋转 90/270 度的源交换目标宽高和 SAR。旋转输入选择 CPU 解码与自动旋转，再上传到硬件编码器。
- 全硬件：VAAPI/CUDA/QSV 先用显式硬件 scale 归一到固定画布，再编码；原分辨率也做尺寸归一，以应对中途变化。随后安全关闭隐式 autoscale。
- 混合模式：需要 hwupload 的 VAAPI/QSV，先用固定尺寸的软件 scale、setsar，再上传编码；此时关闭 autoscale。NVENC/VideoToolbox 等直接接收 CPU 帧的编码路径保留默认 autoscale。
- 不能得到可靠尺寸或没有支持的硬件缩放器：不尝试关闭 autoscale 的全硬件链路。需要上传但缺少尺寸时继续回退到 CPU；纯软件模式保留默认 autoscale 保护。

可变宽高比的各段目前直接缩放到初始画布与显示比例；不动态改变输出宽高，也没有新增补边模式。

现有三级回退、停止保护、输出校验、源文件安全替换继续保留。

## 验证

本地：26 项相关 Node 测试，25 通过、1 因 WebP 编码器缺失跳过、0 失败。新增实际 FFmpeg 可变尺寸输入和旋转元数据测试；语法、格式及 diff 检查通过。

远端（FFmpeg 5.1.9 / Intel VAAPI）验证：

- H.264/H.265 的原尺寸和 240p 归一成功。
- 连续 TS 输入中途从 `320×180` 切换到 `640×480`：逐帧确认原尺寸输出始终为 `320×180`、240p 输出始终为 `426×240`，全硬件成功。
- 人为让硬件解码设备无效：混合编码成功；可变尺寸输入的混合输出也始终为 `320×180`。
- 此前报错的真实源视频 96–106 秒片段仍通过全硬件处理；未重裁整部真实视频。
- 90 度旋转元数据得到 `180×320` 竖屏输出并使用硬件编码。
- 临时生成视频的产出校验与源路径替换通过。

## 发布

更新 `videoTransHardware.js` 与 `videoTransWorker.js`，不重启容器，新启动任务加载新代码。现有 APK 2052 无需更换。

旧文件备份后缀：`.backup-fixed-20261014`；发布目录：`/home/ermao/nascabos-video-release-fixed-20261014`。

生产与本地文件哈希一致：

```text
videoTransHardware.js: 0af8343ee44f352defd897179efdb676b585f829daf708115e7c1b5b908a83f9
videoTransWorker.js: 3bfaf5ee4ed0e3a5f1adca58af9afe676e5470a3b092d45b90c6f8ba33c7b201
```

健康接口正常。新镜像：`nascabos-custom:video-trim-fixed-20261014`，同步 `nascabos-custom:latest`，无暂停提交。

归档：`/home/ermao/appdata/myimage/nascabos-custom-video-trim-fixed-20261014.tar.gz`。已完成（约 2.7 GiB），`gzip -t` 校验通过，并生成 `.sha256` 校验文件。

```text
镜像 ID: sha256:cf12b067285845fbeac804a3d632181ec3bdeace7001630574487f02144e8e58
归档 SHA-256: 24e5c0582580ac9776edc362f1e9175adabedf3369fd5a42c08e4f30ad5b4abb
```
