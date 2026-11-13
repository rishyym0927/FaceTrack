import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'classroom_pending_files_stub.dart'
    if (dart.library.io) 'classroom_pending_files_io.dart' as files;

/// One private recovery queue for the signed-in teacher. No media or upload
/// capability is sent to analytics or stored in browser preferences.
class ClassroomPending {
  ClassroomPending(this.owner, this.institute, this.session);
  final String owner, institute, session;
  static const _prefix = 'facetrack.private.classroom-pending.v1.';
  String get _key => '$_prefix$owner.$institute.$session';
  static Future<void> _tail = Future.value();

  static Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<Map<String, dynamic>?> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      await (await SharedPreferences.getInstance()).remove(_key);
      return null;
    }
  }

  bool _owns(Map<String, dynamic> data) =>
      data['owner'] == owner &&
      data['institute'] == institute &&
      data['session'] == session;

  Future<List<Map<String, dynamic>>> load() => _locked(() async {
    final data = await _read();
    if (data == null) return [];
    late final DateTime created;
    try {
      created = DateTime.parse(data['created'] as String);
    } catch (_) {
      await _clearData(data);
      return [];
    }
    if (!_owns(data) ||
        DateTime.now().difference(created) >= const Duration(hours: 24)) {
      await _clearData(data);
      return [];
    }
    final entries = (data['segments'] as List).cast<Map<String, dynamic>>();
    final valid = <Map<String, dynamic>>[];
    for (final entry in entries) {
      if (await files.exists(entry['path'] as String)) valid.add(entry);
    }
    if (valid.length != entries.length) await _write(valid);
    return valid;
  });

  Future<void> _write(List<Map<String, dynamic>> entries) async {
    final preferences = await SharedPreferences.getInstance();
    final previous = await _read();
    if (entries.isEmpty) {
      await preferences.remove(_key);
    } else {
      await preferences.setString(
        _key,
        jsonEncode({
          'owner': owner,
          'institute': institute,
          'session': session,
          'created': previous != null && _owns(previous)
              ? previous['created']
              : DateTime.now().toUtc().toIso8601String(),
          'segments': entries,
        }),
      );
    }
  }

  Future<XFile> retain(XFile file, Map<String, dynamic> upload) =>
      _locked(() async {
        final data = await _read();
        if (data != null && !_owns(data)) await _clearData(data);
        final entries = data != null && _owns(data)
            ? (data['segments'] as List).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        final path = await files.retain(file.path);
        entries.add({'path': path, 'upload': upload});
        await _write(entries);
        return XFile(path);
      });

  Future<void> update(String path, Map<String, dynamic> upload) =>
      _locked(() async {
        final data = await _read();
        if (data == null || !_owns(data)) return;
        final entries = (data['segments'] as List).cast<Map<String, dynamic>>();
        for (final entry in entries) {
          if (entry['path'] == path) entry['upload'] = upload;
        }
        await _write(entries);
      });

  Future<void> remove(String path) => _locked(() async {
    final data = await _read();
    if (data == null || !_owns(data)) return;
    final entries = (data['segments'] as List).cast<Map<String, dynamic>>()
      ..removeWhere((entry) => entry['path'] == path);
    await _write(entries);
    await files.remove(path);
  });

  Future<void> _clearData(Map<String, dynamic> data) async {
    for (final entry in (data['segments'] as List? ?? [])) {
      if (entry is Map && entry['path'] is String) {
        await files.remove(entry['path'] as String);
      }
    }
    await (await SharedPreferences.getInstance()).remove(_key);
  }

  static Future<void> clearAll() => _locked(() async {
    final preferences = await SharedPreferences.getInstance();
    for (final key in preferences.getKeys().where((key) => key.startsWith(_prefix))) {
      final raw = preferences.getString(key);
      if (raw == null) continue;
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in (data['segments'] as List? ?? [])) {
          if (entry is Map && entry['path'] is String) {
            await files.remove(entry['path'] as String);
          }
        }
      } catch (_) { /* A malformed manifest cannot be recovered. */ }
      await preferences.remove(key);
    }
  });
}
