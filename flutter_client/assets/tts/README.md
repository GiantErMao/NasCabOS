# Bundled offline speech model

These files are packaged in the application. Runtime installation reads assets only; no model download or external service is used.

Sources (retrieved 2026-10-20):
- matcha-icefall-zh-baker.tar.bz2: https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2
- vocos-22khz-univ.onnx: https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx

Sizes and SHA-256 digests are pinned in LocalTtsModelManifest and checked before extraction. Update the bundled files and manifest together.

The DataBaker training data permits non-commercial use only. Source terms: https://www.data-baker.com/open_source.html
The acoustic archive also includes its upstream README.
