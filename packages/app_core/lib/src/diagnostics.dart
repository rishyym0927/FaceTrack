import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';

import 'network_info_stub.dart'
    if (dart.library.js_interop) 'network_info_web.dart'
    as network_info;

/// Sends one batch to the server. Throws when it could not be delivered.
typedef DiagnosticsSender = Future<void> Function(Map<String, dynamic> batch);

/// Anonymous, bounded diagnostics for the web and phone apps.
///
/// Only a fixed list of event names and a few numbers or short codes are ever recorded: no
/// names, emails, tokens, URLs, free text or face data. The server rejects anything else, and
/// [safeCode] / [routeTemplate] make sure we never try. Events are kept in a small buffer and
/// sent in batches; a failure to send is silently dropped. Diagnostics can never interrupt what
/// the teacher is doing, and use no timers: events are sent when enough have piled up, when
/// something urgent happens, when [flushAfter] has passed at the next event, or when the app
/// goes to the background.
class Diagnostics {
  Diagnostics({
    required this.app,
    this.send,
    this.version = const String.fromEnvironment('APP_VERSION'),
    this.flushAfter = const Duration(seconds: 10),
    this.maxBuffered = 100,
    String? platform,
    DateTime Function()? clock,
    String? deviceClass,
    Map<String, Object> Function()? networkContext,
  }) : platform = platform ?? _platformName(),
       _clock = clock ?? DateTime.now,
       _deviceClass = deviceClass,
       _networkContext = networkContext ?? network_info.networkContext;

  final String app; // 'teacher' or 'student'
  final String platform; // 'web' | 'android' | 'ios' | 'other'
  final String version;
  final Duration flushAfter;
  final int maxBuffered;
  final DateTime Function() _clock;
  final Map<String, Object> Function() _networkContext;
  String? _deviceClass;
  DiagnosticsSender? send;
  final _buffer = <_Entry>[];
  // Repeats of the same API failure inside [repeatWindow] become one event with a count: a
  // polling outage must not use the whole budget and crowd out the upload events.
  final _repeats = <String, _Entry>{};
  static const repeatWindow = Duration(seconds: 30);
  DateTime? _lastFlush, _backoffUntil;
  bool _sending = false, _disposed = false;
  int _epoch = 0;
  int dropped = 0;

  /// The only names the server accepts (kept equal to `services/api/app/client_events.py` by
  /// a test). Anything else is dropped here instead of costing the server's whole batch.
  static const knownEvents = {
    'scan_started',
    'scan_stopped',
    'scan_paused',
    'scan_resumed',
    'segment_recorded',
    'upload_retry',
    'upload_failed',
    'upload_done',
    'camera_failed',
    'camera_interrupted',
    'camera_recovered',
    'camera_switched',
    'recognition_load_failed',
    'api_error',
    'app_error',
  };

  /// Problems worth sending immediately, in case the app is about to be closed.
  static const urgent = {
    'app_error',
    'upload_failed',
    'camera_failed',
    'camera_interrupted',
  };

  static String _platformName() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'other',
    };
  }

  /// `phone`, `tablet` or `desktop` from the screen's logical size: a class, never a model.
  static String deviceClassFor(String platform, double shortestSide, double longestSide) {
    if (shortestSide <= 0) return 'unknown';
    if (platform == 'android' || platform == 'ios') {
      if (shortestSide < 600) return 'phone';
      return 'tablet';
    }
    if (shortestSide < 600) return 'phone'; // a phone's browser
    return longestSide >= 1024 ? 'desktop' : 'tablet';
  }

  String _currentDeviceClass() {
    final known = _deviceClass;
    if (known != null) return known;
    try {
      final view = PlatformDispatcher.instance.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      final short = size.shortestSide, long = size.longestSide;
      return _deviceClass = deviceClassFor(platform, short, long);
    } catch (_) {
      return 'unknown';
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// `/v1/sessions/<uuid>/attendance?x=1` becomes `/v1/sessions/{id}/attendance`.
  static String routeTemplate(String path) {
    final bare = path.split('?').first.split('#').first;
    final segments = [
      for (final part in bare.split('/'))
        if (_uuid.hasMatch(part))
          '{id}'
        else if (RegExp(r'^\d+$').hasMatch(part))
          '{n}'
        else
          part.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), ''),
    ];
    final joined = segments.join('/');
    final route = joined.startsWith('/') ? joined : '/$joined';
    return route.length > 100 ? route.substring(0, 100) : route;
  }

  /// A short identifier made only of letters, digits and `_ . -`; null when nothing is left.
  static String? safeCode(Object? value) {
    if (value == null) return null;
    final text = value.toString().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    if (text.isEmpty) return null;
    return text.length > 60 ? text.substring(0, 60) : text;
  }

  /// Records one event. Never throws.
  void record(
    String name, {
    String? sessionId,
    Object? code,
    String? route,
    int? status,
    int? attempt,
    double? seconds,
    int? bytes,
    int? durationMs,
    int? count,
  }) {
    if (_disposed || !knownEvents.contains(name)) return;
    try {
      final safeSession = sessionId != null && _uuid.hasMatch(sessionId)
          ? sessionId
          : null;
      final event = <String, dynamic>{
        'name': name,
        'session_id': ?safeSession,
        if (safeCode(code) case final c?) 'code': c,
        if (route != null) 'route': routeTemplate(route),
        if (status != null && status >= 100 && status <= 599) 'status': status,
        if (attempt != null && attempt >= 0) 'attempt': attempt.clamp(0, 1000),
        if (seconds != null && seconds >= 0) 'seconds': seconds.clamp(0, 3600),
        if (bytes != null && bytes >= 0) 'bytes': bytes.clamp(0, 1000000000),
        if (durationMs != null && durationMs >= 0)
          'duration_ms': durationMs.clamp(0, 3600000),
        if (count != null && count >= 0) 'count': count.clamp(0, 100000),
      };
      final now = _clock();
      if (name == 'api_error') {
        final key = '${event['route']}|${event['status']}|${event['code']}';
        final earlier = _repeats[key];
        if (earlier != null &&
            now.difference(earlier.at) < repeatWindow &&
            _buffer.any((e) => identical(e, earlier))) {
          earlier.event['count'] = ((earlier.event['count'] as int?) ?? 1) + 1;
          return;
        }
        _repeats[key] = _Entry(event, now);
        _buffer.add(_repeats[key]!);
        if (_repeats.length > 50) _repeats.clear();
      } else {
        _buffer.add(_Entry(event, now));
      }
      while (_buffer.length > maxBuffered) {
        _buffer.removeAt(0);
        dropped++;
      }
      final waiting = _backoffUntil != null && now.isBefore(_backoffUntil!);
      final due = _lastFlush == null || now.difference(_lastFlush!) >= flushAfter;
      if (!waiting && (_buffer.length >= 20 || urgent.contains(name) || due)) {
        unawaited(flush());
      }
    } catch (_) {
      // Diagnostics must never break the app.
    }
  }

  /// Sends what is buffered, at most 50 events per request. Safe to call at any time.
  Future<void> flush() async {
    final sender = send;
    if (_disposed || _sending || _buffer.isEmpty || sender == null) return;
    _sending = true;
    _lastFlush = _clock();
    final taken = _buffer.take(50).toList();
    final stamp = _clock();
    // `age_ms` says how long ago each event happened, so the server can place it on the real
    // timeline instead of at the moment the batch arrived.
    final batch = [
      for (final e in taken)
        {
          ...e.event,
          'age_ms': stamp.difference(e.at).inMilliseconds.clamp(0, 86400000),
        },
    ];
    final epoch = _epoch;
    // [clear] may run while the request is out; what is in the buffer afterwards belongs to
    // the next account and must not be trimmed by this batch's result.
    void sent() {
      if (epoch == _epoch) _buffer.removeRange(0, batch.length);
    }

    try {
      await sender({
        'app': app,
        'platform': platform,
        if (version.isNotEmpty &&
            RegExp(r'^[0-9A-Za-z.+-]{1,32}$').hasMatch(version))
          'version': version,
        'device_class': _currentDeviceClass(),
        ..._safeNetwork(),
        'events': batch,
      });
      sent();
      _backoffUntil = null;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null && status >= 400 && status < 500 && status != 429) {
        // The server will never accept this batch (and a 401 means signed out); drop it so
        // one bad event cannot block everything behind it.
        sent();
      } else {
        _backoffUntil = _clock().add(flushAfter * 6);
      }
    } catch (_) {
      // Keep the events; the buffer bound stops any build-up. Back off before the next
      // automatic attempt (a background flush still tries at once).
      _backoffUntil = _clock().add(flushAfter * 6);
    } finally {
      _sending = false;
    }
  }

  Map<String, Object> _safeNetwork() {
    try {
      return {
        for (final e in _networkContext().entries)
          if (const {'network', 'net_class', 'downlink_mbps', 'rtt_ms'}.contains(e.key))
            e.key: e.value,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Forgets buffered events, so they are never sent under another account.
  void clear() {
    _epoch++;
    _buffer.clear();
    _repeats.clear();
  }

  @visibleForTesting
  List<Map<String, dynamic>> get pending => [for (final e in _buffer) e.event];

  void dispose() => _disposed = true;
}

class _Entry {
  _Entry(this.event, this.at);
  final Map<String, dynamic> event;
  final DateTime at;
}
