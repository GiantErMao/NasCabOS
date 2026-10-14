# 替换源文件保存校验热修复（2052）

日期：2026-10-14。APK 版本 `1.2.7 (2052)`。

## 问题与修复

替换模式下，弹窗允许保存目录为空，服务端也接受空目录，但 Flutter `VideoTransController.upsert` 仍无条件检查来源和目录均非空，导致请求在到达服务端前被拦截。

修复文件：`flutter_client/lib/modules/mediaTool/video_trans/controller/video_trans_controller.dart`。

- `replace_source == true` 时允许空保存目录，并将隐藏的旧保存目录从请求中清空。
- 普通转换仍要求目录；所有模式仍要求来源。
- 增加可选 API 注入，默认使用原有 API 服务，便于测试真实控制器保存行为。

## 验证

`flutter test --no-pub test/video_trans_controller_test.dart`：4 项全部通过，覆盖替换空目录发送 API 请求、编辑时清除旧目录、普通转换必填目录及替换模式来源必填。

控制器与测试文件 Dart 分析：`No issues found!`。

Web 和 APK Release 构建成功。APK v2/v3 签名通过，沿用已有内部测试证书。

## 部署与安装

本次仅更新 Flutter Web 和 APK，服务端已支持此参数组合，无需修改。

- 远端 Web 已热切换；健康接口正常，不重启正在运行的服务。
- Web 备份：`/nascabos/web/main.backup-video-trim-v2052-20261014`。
- 发布目录：`/home/ermao/nascabos-video-release-v2052`。
- 本地构建、容器文件与公网下载的 `main.dart.js` 哈希相同：

```text
14b9c20e78f43f14cdea1e97d475fba881c626bf094761f139568ff234fcdca5
```

APK：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2052.apk`。

```text
SHA-256: 02e38a9ed31483f4ad80a0702100cfa085d9958734c6a66e35b521b1268d9d28
```

ADB `install --no-incremental -r` 返回 `Success`，设备 `e6fc7cb7` 版本为 `1.2.7 (2052)`，应用启动返回 `Status: ok`。保留原应用数据；启动后显示系统权限提示，未自动授权，也未在真实设备界面中再次保存任务。

浏览器需强制刷新后加载热修复；设备先处理系统权限提示，再重新打开任务弹窗保存。

## 镜像持久化

新镜像：`nascabos-custom:video-trim-v2052-20261014`，并更新 `nascabos-custom:latest`。

镜像 ID：`sha256:1ea07405c22fa1e991450cf365b0f8ec49b4cbc03ae476a4c8649b32d4a4ff4b`。

归档：`/home/ermao/appdata/myimage/nascabos-custom-video-trim-v2052-20261014.tar.gz`。归档已完成，约 2.7 GiB，`gzip -t` 完整性检查通过，并生成 `.sha256` 校验文件。

```text
SHA-256: b0c443c457b7701148881778c6444925ea5142eba5d923e34c630e77f22cb017
```
