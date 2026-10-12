class LocalTtsArtifact {
  const LocalTtsArtifact({
    required this.fileName,
    required this.url,
    required this.length,
    required this.sha256,
  });

  final String fileName;
  final String url;
  final int length;
  final String sha256;
}

class LocalTtsVoicePreset {
  const LocalTtsVoicePreset({
    required this.sid,
    required this.name,
    required this.locale,
    required this.gender,
  });

  final int sid;
  final String name;
  final String locale;
  final String gender;
}

class LocalTtsModelManifest {
  const LocalTtsModelManifest._();

  static const String id = 'matcha-icefall-zh-baker-v1';
  static const int version = 1;
  static const String displayName = 'Matcha Baker + Vocos';
  static const String locale = 'zh-CN';
  static const int minimumFreeBytes = 350 * 1024 * 1024;
  static const String licenseUrl =
      'https://www.data-baker.com/open_source.html';
  static const String licenseNotice =
      'The DataBaker training data permits non-commercial use only. '
      'Review and comply with the source license before downloading.';

  static const LocalTtsArtifact acousticArchive = LocalTtsArtifact(
    fileName: 'matcha-icefall-zh-baker.tar.bz2',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
        'matcha-icefall-zh-baker.tar.bz2',
    length: 75480421,
    sha256: 'fc41b5115c45ffab7f46e1a5a0fcefd15b2698e32ca5d080dde7a5e7caa2fe56',
  );

  static const LocalTtsArtifact vocoder = LocalTtsArtifact(
    fileName: 'vocos-22khz-univ.onnx',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
        'vocoder-models/vocos-22khz-univ.onnx',
    length: 53884024,
    sha256: '0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081',
  );

  static const List<LocalTtsArtifact> artifacts = <LocalTtsArtifact>[
    acousticArchive,
    vocoder,
  ];

  static const List<String> requiredFiles = <String>[
    'matcha-icefall-zh-baker/model-steps-3.onnx',
    'matcha-icefall-zh-baker/lexicon.txt',
    'matcha-icefall-zh-baker/tokens.txt',
    'matcha-icefall-zh-baker/phone.fst',
    'matcha-icefall-zh-baker/date.fst',
    'matcha-icefall-zh-baker/number.fst',
    'vocos-22khz-univ.onnx',
  ];

  static const List<String> legacyModelIds = <String>[
    'kokoro-int8-multi-lang-v1_1',
  ];

  static const List<LocalTtsVoicePreset> voices = <LocalTtsVoicePreset>[
    LocalTtsVoicePreset(
      sid: 0,
      name: 'Baker 中文女声',
      locale: 'zh-CN',
      gender: 'female',
    ),
  ];

  static int get downloadBytes =>
      artifacts.fold<int>(0, (sum, artifact) => sum + artifact.length);
}
