import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;

class PendingClip {
  PendingClip({
    required this.owner,
    required this.institute,
    required this.attempt,
    required this.path,
    required this.mime,
    required this.completeKey,
    required this.created,
    this.missedGuidance = const [],
    this.uploadUrl,
  });
  final String owner, institute, attempt, path, mime, completeKey;
  final DateTime created;
  final List<String> missedGuidance;
  String? uploadUrl;
  XFile get file => XFile(path);
  Map<String, dynamic> toJson() => {
    'owner': owner,
    'institute': institute,
    'attempt': attempt,
    'path': path,
    'mime': mime,
    'complete_key': completeKey,
    'created': created.toUtc().toIso8601String(),
    'missed_guidance': missedGuidance,
    'upload_url': uploadUrl,
  };
  factory PendingClip.fromJson(Map<String, dynamic> j) => PendingClip(
    owner: j['owner'],
    institute: j['institute'],
    attempt: j['attempt'],
    path: j['path'],
    mime: j['mime'],
    completeKey: j['complete_key'],
    created: DateTime.parse(j['created']),
    missedGuidance:
        (j['missed_guidance'] as List<dynamic>?)?.cast<String>() ?? const [],
    uploadUrl: j['upload_url'],
  );
}

class PendingClips {
  static const key = 'facetrack.private.pending-enrolment.v1';
  static PendingClip? memory;
  static Future<PendingClip?> read() async {
    if (kIsWeb) return memory;
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return null;
    try {
      return PendingClip.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(PendingClip clip) async {
    memory = clip;
    if (!kIsWeb)
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode(clip.toJson()),
      );
  }

  static Future<PendingClip> retain(PendingClip clip) async {
    final path = await files.retain(clip.path, clip.attempt);
    final retained = PendingClip(
      owner: clip.owner,
      institute: clip.institute,
      attempt: clip.attempt,
      path: path,
      mime: clip.mime,
      completeKey: clip.completeKey,
      created: clip.created,
      missedGuidance: clip.missedGuidance,
      uploadUrl: clip.uploadUrl,
    );
    await save(retained);
    return retained;
  }

  static Future<void> clear() async {
    final old = await read();
    if (old != null) await files.remove(old.path);
    memory = null;
    if (!kIsWeb) await (await SharedPreferences.getInstance()).remove(key);
  }

  static Future<void> expire({String? owner}) async {
    final old = await read();
    if (old != null &&
        (DateTime.now().difference(old.created) >= const Duration(hours: 24) ||
            (owner != null && old.owner != owner)))
      await clear();
  }
}
