import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.facetrack/screen');

/// Keeps the phone's screen on (Android only) while a scan is open. A screen timeout pauses the
/// app, which ends the scan. Silently does nothing where there is no native side (web, tests).
Future<void> keepScreenAwake(bool on) async {
  try {
    await _channel.invokeMethod<void>('keepAwake', on);
  } on MissingPluginException {
    // Not Android.
  } on PlatformException {
    // The screen may then time out; the scan itself is unaffected.
  }
}
