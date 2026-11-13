import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;
import 'pending_store_stub.dart'
    if (dart.library.js_interop) 'pending_store_web.dart' as browserStore;

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
  static final Queue<Future<void> Function()> _waiting = Queue();
  static bool _running = false;

  static Future<T> _exclusive<T>(Future<T> Function() work) {
    final result = Completer<T>();

    Future<void> run() async {
      try {
        result.complete(await work());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        if (_waiting.isEmpty) {
          _running = false;
        } else {
          _running = true;
          unawaited(_waiting.removeFirst()());
        }
      }
    }

    if (_running) {
      _waiting.add(run);
    } else {
      _running = true;
      unawaited(run());
    }
    return result.future;
  }

  static Future<PendingClip?> _read() async {
    if (kIsWeb) {
      final raw = await browserStore.read();
      if (raw == null) return memory;
      return PendingClip.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
    }
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return null;
    try {
      return PendingClip.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _save(PendingClip clip) async {
    memory = clip;
    if (kIsWeb) {
      await browserStore.save(jsonEncode(clip.toJson()), clip.path);
    } else {
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode(clip.toJson()),
      );
    }
  }

  static Future<void> _clear() async {
    final old = await _read();
    if (old != null) await files.remove(old.path);
    memory = null;
    if (kIsWeb) {
      await browserStore.clear();
    } else {
      await (await SharedPreferences.getInstance()).remove(key);
    }
  }

  static Future<PendingClip?> read() => _exclusive(_read);

  static Future<void> save(PendingClip clip) => _exclusive(() => _save(clip));

  /// Updates an existing recording only. Cleanup/logout winning the race means
  /// a late upload checkpoint cannot recreate its private capability metadata.
  static Future<bool> update(PendingClip clip) => _exclusive(() async {
    final current = await _read();
    if (current == null ||
        current.owner != clip.owner ||
        current.institute != clip.institute ||
        current.attempt != clip.attempt ||
        current.path != clip.path) {
      return false;
    }
    await _save(clip);
    return true;
  });

  static Future<PendingClip> retain(PendingClip clip) => _exclusive(() async {
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
    await _save(retained);
    return retained;
  });

  static Future<void> clear() => _exclusive(_clear);

  static Future<void> expire({String? owner}) => _exclusive(() async {
    final old = await _read();
    if (old != null &&
        (DateTime.now().difference(old.created) >= const Duration(hours: 24) ||
            (owner != null && old.owner != owner)))
      await _clear();
  });
}
