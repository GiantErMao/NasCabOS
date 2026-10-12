# NasCabOS Current Development Progress

Last updated: 2026-10-10

This document summarizes the current implementation and deployment state for continuing work in a new conversation.

## Project

- Workspace: `/Users/bytedance/P4Workspace/NasCabOS`
- Deployment guide: `docs/DEPLOYMENT_AND_ANDROID_BUILD.md`

## Movie Scraping

- The original scraping pipeline used TMDB plus local NFO generation.
- MetaTube support has been added for title/code based adult video metadata scraping.
- MetaTube service URL has no built-in default and must be configured by the user.
- MetaTube integration supports:
  - provider listing
  - movie search
  - movie detail fetch
  - image download
  - fallback when a provider detail endpoint fails
- The automatic scraping path now tries multiple MetaTube candidates and prefers results with usable detail metadata such as `summary` and `genres`.

Key files:

- `electron_server/src/workers/videoIndex/nfoFetchWorker/metatubeClient.js`
- `electron_server/src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
- `electron_server/src/workers/videoIndex/nfoFetchWorker/jellyfinNfo.js`

## NFO Metadata Translation

- Scraped metadata translation has been added.
- Default behavior remains unchanged unless translation is enabled.
- When enabled, the default translated fields are:
  - `summary` / `plot`
  - `genres`
- Title translation is controlled by a separate switch:
  - `nfoTranslateTitleEnable`
- Supported custom translation configuration:
  - `nfoTranslateApiUrl`
  - `nfoTranslateApiKey`
  - `nfoTranslateTargetLanguage`
- The current translation client supports LibreTranslate-compatible APIs.
- Google Translate and MyMemory public endpoints were tested and hit HTTP 429, so they should not be treated as stable default services.
- Actual scraping validation has passed on `indexId=6213`; service logs showed:
  - `[nfoTranslate] translated fields: plot,genres,title`

Key files:

- `electron_server/src/workers/videoIndex/nfoFetchWorker/metadataTranslateClient.js`
- `electron_server/src/api/modules/video/config/videoConfigController.js`
- `flutter_client/lib/modules/video/other_setting/controller/video_other_settings_controller.dart`
- `flutter_client/lib/modules/video/other_setting/service/video_tmdb_settings_api_service.dart`
- `flutter_client/lib/modules/video/other_setting/view/video_other_settings_view.dart`
- `flutter_client/lib/core/languages/zh_cn.dart`
- `flutter_client/lib/core/languages/en_us.dart`

Notes:

- If a local `libredeepl` deployment is not LibreTranslate-compatible, add a DeepL or DeepLX compatible adapter before using it as the NFO translation backend.

## Remote Deployment

- Remote SSH:
  - `ermao@ddns.ermao.fun:13122`
- Container:
  - `nascabos`
- Public web URL:
  - `http://ddns.ermao.fun:18761/`
- Container paths:
  - server source: `/nascabos/src`
  - web build: `/nascabos/web/main`
- SSH key based login has been configured.
- Do not save or repeat remote passwords in documentation. A sudo password was previously shared in chat and should be rotated on the server.

## Android APK

- Last built and signed APK:
  - `flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2042-signed.apk`
- Version:
  - `1.2.7 (2042)`
- Installed test device:
  - `e6fc7cb7`
- Flutter SDK path:
  - `/Users/bytedance/Env/flutter`

Known environment note:

- `flutter analyze` has printed `No issues found`, but the sandbox can block writes under `~/.dartServer/.analysis-driver`. Treat that as environment noise when the analyzer result itself is clean.

## Docker Hardware Decode / Transcode

The remote physical host supports Intel VAAPI/QSV:

- GPU: Intel Alder Lake-S GT1 / UHD Graphics 730
- Driver: `i915`
- Render device: `/dev/dri/renderD128`
- `vainfo` works on the host
- Supported capabilities include H.264, HEVC/H.265, HEVC Main10, VP9, and AV1 decode.

The `nascabos` container has been rebuilt while preserving the original port mapping and mounts. The rebuild added:

- `/dev/dri:/dev/dri`
- `video` and `render` group permissions
- Intel VAAPI driver inside the container:
  - `intel-media-va-driver`

Current application hardware probe selection:

- VAAPI device:
  - `/dev/dri/renderD128`
- Encoders:
  - `h264_vaapi`
  - `hevc_vaapi`
- Decode args:
  - `-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi`

## VAAPI hw_full Fix

Problem:

- `transcodeWorker.js` had support for VAAPI full hardware decode inside `startOnePass('hw_full')`.
- The outer `canTryFull` condition was still hardcoded to `h264_nvenc + cuda`.
- As a result, Intel VAAPI could never enter the `hw_full` path and instead used `hw_encode`.

Fix:

- `canTryFull` now supports:
  - CUDA/NVENC full path
  - VAAPI full path
- CUDA and VAAPI full decode checks were split into helper functions.

Key file:

- `electron_server/src/workers/transcodeWorker.js`

Latest remote image archive for this fix:

- `/home/ermao/appdata/myimage/nascabos-custom-vaapi-full-entry-20261009-214202.tar.gz`
- SHA-256:
  - `999ef30e86ea744ed94b1d4ac461ee7b41c2abc01cee4410424a283b911a43ed`

## hw_full Playback Validation

A live transcode playback was verified over SSH. The active FFmpeg command contained:

```text
-hwaccel vaapi
-hwaccel_device /dev/dri/renderD128
-hwaccel_output_format vaapi
-vaapi_device /dev/dri/renderD128
-filter:v scale_vaapi=w=854:h=-2
-c:v h264_vaapi
```

Conclusion:

- The current transcode playback path is using server-side VAAPI full hardware transcode:
  - hardware decode
  - GPU scaling
  - hardware encode

## VAAPI CPU Decode Fallback Fix

Problem found on 2026-10-10:

- VAAPI full decode was entered correctly, but some playback sessions still fell back to CPU.
- Two confirmed causes:
  - Portrait videos requested as `width=3840` were scaled to invalid dimensions such as `3840x6832`, exceeding Intel VAAPI encoder constraints (`height 32-4096`).
  - MPEG-4 Part 2 sources (`codec_name=mpeg4`, Simple Profile) are not supported by the current VAAPI full-decode path, so FFmpeg failed with `No support for codec mpeg4 profile 0`.

Fix:

- Playback transcode now treats the client quality width as a target long edge for portrait sources, so 4K portrait H.264 becomes `scale_vaapi=w=2160:h=-2` instead of `3840x6832`.
- VAAPI `hw_full` is only attempted for known-supported source codecs:
  - H.264
  - HEVC/H.265
  - VP9
  - AV1
- Unsupported codecs such as MPEG-4 Part 2 now go directly to CPU decode plus VAAPI hardware encode when available, avoiding one failed full-hardware attempt.

Key file:

- `electron_server/src/workers/transcodeWorker.js`

Latest remote image archive for this fix:

- `/home/ermao/appdata/myimage/nascabos-custom-vaapi-decode-fallback-20261010-104836.tar.gz`
- SHA-256:
  - `f7fcffaeb15535ea289da79a8ba8ed62b4978baea64b8e38f3e3927d2e6cfc5a`

## Recent Important Images

- MetaTube and translation related:
  - `nascabos-custom:20261009-210114`
- Docker hardware decode rebuild:
  - `nascabos-custom-hwdecode-20261009-213314`
- VAAPI `hw_full` entry fix:
  - `nascabos-custom:vaapi-full-entry-20261009-214202`
- VAAPI decode fallback and portrait target-width fix:
  - `nascabos-custom:vaapi-decode-fallback-20261010-104836`

## Suggested Next Work

- Validate more video formats under VAAPI `hw_full`:
  - H.264
  - HEVC
  - 10-bit sources
  - subtitle burn-in
  - HDR sources
- Subtitle burn-in and HDR tone mapping currently require CPU-side filters and may fall back to soft decode plus VAAPI hardware encode.
- If `libredeepl` does not expose a LibreTranslate-compatible `/translate` API, add a DeepL/DeepLX-compatible translation adapter.
