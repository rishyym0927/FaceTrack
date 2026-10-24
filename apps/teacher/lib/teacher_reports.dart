import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class TeacherReports extends StatefulWidget {
  const TeacherReports({
    super.key,
    required this.api,
    required this.institute,
    required this.sessionId,
    required this.supabaseUrl,
    required this.sessionVersion,
  });
  final ApiClient api;
  final String institute, sessionId, supabaseUrl;
  final int sessionVersion;
  @override
  State<TeacherReports> createState() => _TeacherReportsState();
}

class _TeacherReportsState extends State<TeacherReports> {
  List<Json> reports = [];
  final details = <String, Json>{};
  String? error;
  bool busy = false;
  bool loading = true, foreground = true;
  int generation = 0;
  Future<void>? inFlight;
  AppLifecycleListener? lifecycle;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    lifecycle = AppLifecycleListener(
      onHide: () => foreground = false,
      onPause: () => foreground = false,
      onResume: () {
        foreground = true;
        unawaited(refresh());
      },
    );
    timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (foreground &&
          (reports.any((r) => ['queued', 'processing'].contains(r['status'])) ||
              details.values.any(
                (r) => (r['deliveries'] as List? ?? []).any(
                  (d) => ['queued', 'processing'].contains(d['status']),
                ),
              ))) {
        unawaited(refresh());
      }
    });
  }

  @override
  void didUpdateWidget(covariant TeacherReports oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.institute != widget.institute) {
      generation++;
      inFlight = null;
      reports = [];
      details.clear();
      error = null;
      unawaited(refresh());
    } else if (oldWidget.sessionVersion != widget.sessionVersion) {
      unawaited(refreshAfterCurrent());
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    lifecycle?.dispose();
    generation++;
    super.dispose();
  }

  Future<void> refreshAfterCurrent() async {
    await inFlight;
    if (mounted) await refresh();
  }

  Future<void> refresh() {
    if (inFlight != null) return inFlight!;
    final current = ++generation;
    final future = loadReports(current);
    inFlight = future;
    return future.whenComplete(() {
      if (identical(inFlight, future)) inFlight = null;
    });
  }

  Future<void> loadReports(int current) async {
    setState(() => loading = true);
    try {
      final list = await widget.api.send(
        'GET',
        '/v1/sessions/${widget.sessionId}/reports',
        institute: widget.institute,
      );
      final items = (list['items'] as List).cast<Json>();
      if (!mounted || current != generation) return;
      // Only published reports expose delivery actions and metadata.
      final finals = items.where((r) => r['kind'] == 'final').toList();
      final metadata = await Future.wait(
        finals.map(
          (r) => widget.api.send(
            'GET',
            '/v1/reports/${r['id']}',
            institute: widget.institute,
          ),
        ),
      );
      if (!mounted || current != generation) return;
      setState(() {
        reports = items;
        details.clear();
        for (var i = 0; i < finals.length; i++) {
          details[finals[i]['id'] as String] = metadata[i];
        }
        error = null;
      });
    } catch (e) {
      if (mounted && current == generation) {
        setState(() {
          error = e.toString();
          if (e is AppFailure && [401, 403, 404].contains(e.status)) {
            reports = [];
            details.clear();
          }
        });
      }
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  Future<void> run(Future<void> Function() job) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await job();
      await refreshAfterCurrent();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download(String id, String kind, String format) => run(() async {
    final grant = await widget.api.send(
      'GET',
      '/v1/reports/$id/download',
      institute: widget.institute,
      query: {'format': format},
    );
    final url = Uri.parse(grant['url'] as String);
    if (url.scheme != 'https' ||
        url.host != Uri.parse(widget.supabaseUrl).host ||
        !url.path.startsWith('/storage/v1/object/sign/')) {
      throw const AppFailure('The report link was invalid. Refresh and retry.');
    }
    final response =
        await Dio(
          BaseOptions(
            followRedirects: false,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
          ),
        ).get<List<int>>(
          url.toString(),
          options: Options(responseType: ResponseType.bytes),
        );
    final bytes = Uint8List.fromList(response.data ?? []);
    if (bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
      throw const AppFailure('Report download was incomplete.');
    }
    await FilePicker.saveFile(
      fileName: 'facetrack-$kind-${widget.sessionId}.$format',
      bytes: bytes,
      mimeType: format == 'pdf' ? 'application/pdf' : 'text/csv',
      dialogTitle: 'Save attendance report',
    );
  });

  Future<void> deliver(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Email the published report?'),
        content: const Text(
          'FaceTrack sends a download link only to your verified institute faculty address. Provider acceptance does not confirm inbox delivery.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await run(() async {
      await widget.api.send(
        'POST',
        '/v1/reports/$id/deliveries',
        institute: widget.institute,
        mutation: Mutation(),
      );
    });
  }

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Attendance reports',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        const Text(
          'Drafts follow closed sessions; final reports use the published attendance revision.',
        ),
        TextButton(
          onPressed: busy || loading ? null : refresh,
          child: const Text('Refresh reports'),
        ),
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (loading)
          const LinearProgressIndicator(semanticsLabel: 'Loading reports'),
        if (reports.isEmpty && error == null && !loading)
          const Text('No reports yet. Close a session or publish attendance.'),
        for (final report in reports) ...[
          const Divider(),
          Text(
            '${report['kind'] == 'final' ? 'Published' : 'Draft'} · revision ${report['source_version']}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          StatusBadge(report['status']),
          const SizedBox(height: 12),
          if (report['status'] == 'ready')
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => download(report['id'], report['kind'], 'csv'),
                  child: const Text('Download CSV'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => download(report['id'], report['kind'], 'pdf'),
                  child: const Text('Download PDF'),
                ),
                if (report['kind'] == 'final' &&
                    details[report['id']]?['email_configured'] == true)
                  OutlinedButton(
                    onPressed: busy ? null : () => deliver(report['id']),
                    child: const Text('Email faculty link'),
                  ),
              ],
            ),
          if (report['kind'] == 'final' &&
              details[report['id']]?['email_configured'] != true)
            const Text(
              'Email delivery is not configured. Downloads are available.',
            ),
          if (report['status'] == 'failed')
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      await widget.api.send(
                        'POST',
                        '/v1/reports/${report['id']}/retry',
                        institute: widget.institute,
                        mutation: Mutation(),
                      );
                    }),
              child: const Text('Retry report generation'),
            ),
          for (final delivery
              in (details[report['id']]?['deliveries'] as List? ?? []))
            Text(
              'Email: ${delivery['status'] == 'sent' ? 'accepted by provider' : delivery['status']}',
            ),
        ],
      ],
    ),
  );
}
