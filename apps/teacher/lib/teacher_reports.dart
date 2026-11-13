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
        query: const {'include_deliveries': true},
      );
      final items = (list['items'] as List).cast<Json>();
      if (!mounted || current != generation) return;
      // Only published reports expose delivery actions and metadata.
      final finals = items.where((r) => r['kind'] == 'final').toList();
      final metadata = await Future.wait(
        finals.map(
          (r) => r.containsKey('deliveries')
              ? Future.value(r)
              : widget.api.send(
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: busy || loading ? null : refresh,
            child: const Text('Refresh reports'),
          ),
        ),
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Text(error!, style: TextStyle(color: scheme.error)),
          ),
        if (loading)
          const LinearProgressIndicator(semanticsLabel: 'Loading reports'),
        if (reports.isEmpty && error == null && !loading)
          Panel(
            padding: 18,
            child: Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'No reports yet. Close a session or publish attendance.',
                  ),
                ),
              ],
            ),
          ),
        for (final report in reports)
          Builder(
            builder: (context) {
              final finalReport = report['kind'] == 'final';
              final ready = report['status'] == 'ready';
              final created = report['created_at'] is String
                  ? DateTime.parse(report['created_at'] as String).toLocal()
                  : null;
              final detail = details[report['id']];
              final deliveries = (detail?['deliveries'] as List?) ?? const [];
              return Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color:
                                (finalReport
                                        ? const Color(0xff176451)
                                        : const Color(0xff9a6a00))
                                    .withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            finalReport
                                ? Icons.verified_outlined
                                : Icons.edit_note,
                            color: finalReport
                                ? const Color(0xff176451)
                                : const Color(0xff9a6a00),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${finalReport ? 'Final report' : 'Draft report'} · version ${report['source_version']}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (created != null)
                                Text(
                                  '${l.formatMediumDate(created)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(created))}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (!ready) StatusBadge(report['status']),
                      ],
                    ),
                    if (ready) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: busy
                                ? null
                                : () => download(
                                    report['id'],
                                    report['kind'],
                                    'pdf',
                                  ),
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('Download PDF'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => download(
                                    report['id'],
                                    report['kind'],
                                    'csv',
                                  ),
                            icon: const Icon(Icons.table_chart_outlined),
                            label: const Text('Download CSV'),
                          ),
                          if (finalReport &&
                              detail?['email_configured'] == true)
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => deliver(report['id']),
                              icon: const Icon(Icons.mail_outline),
                              label: const Text('Email faculty link'),
                            ),
                        ],
                      ),
                    ],
                    if (report['status'] == 'failed') ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
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
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry report generation'),
                      ),
                    ],
                    for (final delivery in deliveries)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          switch (delivery['status']) {
                            'sent' => 'Email link accepted for delivery.',
                            'failed' => 'Email could not be sent. Download the report instead.',
                            'queued' || 'pending' => 'Email is being sent…',
                            _ => 'Email: ${delivery['status']}',
                          },
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}
