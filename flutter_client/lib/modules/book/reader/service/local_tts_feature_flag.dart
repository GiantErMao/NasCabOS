import 'package:flutter/foundation.dart';

bool get localTtsAvailable =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
