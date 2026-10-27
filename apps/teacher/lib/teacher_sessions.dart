import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:crypto/crypto.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'attendance_table.dart';
import 'teacher_timetable.dart';
import 'teacher_reports.dart';

String sessionDate(BuildContext context, String stamp) {
  final d = DateTime.parse(stamp).toLocal(),
      l = MaterialLocalizations.of(context);
  return '${l.formatMediumDate(d)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}';
}

String sessionLabel(String state) => switch (state) {
  'scheduled' => 'Scheduled',
  'open' => 'Open for capture',
  'review_required' => 'Ready for review',
  'no_data' => 'Needs manual assessment',
  'finalized' => 'Published',
  'cancelled' => 'Cancelled',
  _ => 'Closed',
};

class TeacherSessions extends StatefulWidget {
  const TeacherSessions({
    super.key,
    required this.api,
    required this.institute,
    required this.offering,
    required this.publishableKey,
  });
  final ApiClient api;
  final String institute, offering, publishableKey;
  @override
  State<TeacherSessions> createState() => _TeacherSessionsState();
}

class _TeacherSessionsState extends State<TeacherSessions> {
  late final PagedController<Json> controller;
  @override
  void initState() {
    super.initState();
    controller = PagedController(
      (cursor) async => PageData.fromJson(
        await widget.api.send(
          'GET',
          '/v1/sessions',
          institute: widget.institute,
          query: {'offering_id': widget.offering, 'cursor': ?cursor},
        ),
        (j) => j,
      ),
    );
    controller.load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> create() async {
    final room = TextEditingController();
    DateTime start = DateTime.now();
    int minutes = 60;
    await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => ActionDialog(
          title: 'Create attendance session',
          button: 'Create session',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Opening this session freezes its approved student roster. Recognition suggestions require your review.',
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: start,
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 180)),
                  );
                  if (d == null || !context.mounted) return;
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(start),
                  );
                  if (t != null) {
                    setLocal(
                      () => start = DateTime(
                        d.year,
                        d.month,
                        d.day,
                        t.hour,
                        t.minute,
                      ),
                    );
                  }
                },
                child: Text(
                  'Start: ${sessionDate(context, start.toIso8601String())}',
                ),
              ),
              DropdownButtonFormField<int>(
                initialValue: minutes,
                decoration: const InputDecoration(labelText: 'Duration'),
                items: [30, 45, 60, 90, 120]
                    .map(
                      (m) =>
                          DropdownMenuItem(value: m, child: Text('$m minutes')),
                    )
                    .toList(),
                onChanged: (v) => minutes = v!,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: room,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Room (optional)'),
              ),
            ],
          ),
          submit: (mutation) async {
            await widget.api.send(
              'POST',
              '/v1/sessions',
              institute: widget.institute,
              mutation: mutation,
              body: {
                'offering_id': widget.offering,
                'starts_at': start.toUtc().toIso8601String(),
                'ends_at': start
                    .add(Duration(minutes: minutes))
                    .toUtc()
                    .toIso8601String(),
                'room_label': room.text.trim(),
              },
            );
          },
        ),
      ),
    );
    room.dispose();
    await controller.load();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 12,
        children: [
          FilledButton.icon(
            onPressed: create,
            icon: const Icon(Icons.add),
            label: const Text('Create session'),
          ),
          OutlinedButton(
            onPressed: () => controller.load(),
            child: const Text('Refresh sessions'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      ExpansionTile(
        title: const Text('Import timetable'),
        subtitle: const Text('Upload a CSV and confirm scheduled sessions.'),
        children: [
          TeacherTimetable(
            api: widget.api,
            institute: widget.institute,
            offering: widget.offering,
            publishableKey: widget.publishableKey,
            changed: () => controller.load(),
          ),
        ],
      ),
      const SizedBox(height: 16),
      PagedList<Json>(
        controller: controller,
        emptyTitle: 'No sessions yet',
        emptyMessage: 'Create a session to take attendance for this subject.',
        item: (s) => Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sessionDate(context, s['starts_at']),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '${sessionLabel(s['status'])}${s['room_label'] == '' ? '' : ' · ${s['room_label']}'}',
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.go('/sessions/${s['id']}'),
                child: Text(switch (s['status']) {
                  'finalized' => 'View published attendance',
                  'review_required' || 'no_data' => 'Review attendance',
                  'open' => 'Continue session',
                  _ => 'View session',
                }),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class TeacherSessionDetail extends ConsumerStatefulWidget {
  const TeacherSessionDetail({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TeacherSessionDetail> createState() =>
      _TeacherSessionDetailState();
}

class _TeacherSessionDetailState extends ConsumerState<TeacherSessionDetail> {
  late final AppServices services;
  late final String institute;
  Json? data;
  AppFailure? error;
  bool busy = false, ack = false;
  final decisions = <String, String>{};
  final camera = GuidedCamera();
  ResumableUpload? uploader;
  double? progress;
  Json? capture;
  Future<Json>? captureStatusRequest;
  String? captureStatusId;
  DateTime? recordedAt;
  late final SessionExitGuard exitGuard;
  final reserve = Mutation(), complete = Mutation();
  Timer? poll;
  AppLifecycleListener? lifecycle;
  int loadGeneration = 0;
  @override
  void initState() {
    super.initState();
    services = ref.read(servicesProvider);
    institute = ref.read(authProvider).institute!;
    exitGuard = ref.read(sessionExitGuardProvider)..enter(widget.id);
    camera.addListener(changed);
    lifecycle = AppLifecycleListener(
      onPause: () => camera.interrupt(),
      onResume: load,
    );
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<Json> captureStatus(String id) {
    if (captureStatusId != id || captureStatusRequest == null) {
      captureStatusId = id;
      captureStatusRequest = _loadCaptureStatus(id);
    }
    return captureStatusRequest!;
  }

  Future<Json> _loadCaptureStatus(String id) async {
    final result = await services.api.send(
      'GET',
      '/v1/captures/$id',
      institute: institute,
    );
    if (!mounted || capture?['id'] != id) return result;
    final next = result['status'] as String?;
    if (next != null && capture?['status'] != next) {
      setState(() => capture = {...capture!, 'status': next});
      final sessionStatus = (data?['session'] as Json?)?['status'];
      if (sessionStatus != 'open' && !_captureIsPending(next)) {
        poll?.cancel();
        poll = null;
      }
    }
    return result;
  }

  void syncExitGuard() {
    final rows = (data?['items'] as List?)?.cast<Json>() ?? const <Json>[];
    exitGuard.dirty = decisions.entries.any(
      (choice) => rows.any(
        (row) =>
            row['student_id'] == choice.key && row['status'] != choice.value,
      ),
    );
  }

  Future<void> refreshWithConfirmation() async {
    syncExitGuard();
    if (exitGuard.dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Discard unsaved decisions?'),
          content: const Text(
            'Refreshing will discard your unsaved attendance choices.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Discard changes'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    await load(discardChanges: true);
  }

  Future<void> load({bool discardChanges = false}) async {
    if (decisions.isNotEmpty && !busy && !discardChanges) return;
    final current = ++loadGeneration;
    try {
      final result = await services.api.send(
        'GET',
        '/v1/sessions/${widget.id}/attendance',
        institute: institute,
      );
      if (!mounted || current != loadGeneration) return;
      setState(() {
        data = result;
        error = null;
        decisions.clear();
        // Pre-fill only once processing is over, so polling keeps refreshing
        // while a capture is still running.
        if (const {'closed', 'review_required', 'no_data'}
                .contains(result['session']['status']) &&
            !_captureIsPending(capture?['status'])) {
          decisions.addAll(
            draftAbsentDecisions((result['items'] as List).cast<Json>()),
          );
        }
        syncExitGuard();
        captureStatusRequest = null;
      });
      poll?.cancel();
      if (result['session']['status'] == 'open' ||
          _captureIsPending(capture?['status'])) {
        poll = Timer(const Duration(seconds: 5), () => load());
      }
    } catch (e) {
      if (mounted && current == loadGeneration) {
        setState(
          () => error = e is AppFailure
              ? e
              : const AppFailure('Could not load this session. Retry.'),
        );
      }
    }
  }

  Future<void> action(Future<void> Function() fn) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    exitGuard.busy = true;
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is AppFailure
              ? e
              : const AppFailure(
                  'The action did not finish. Retry without leaving this page.',
                ),
        );
      }
    } finally {
      exitGuard.busy = false;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> transition(String name) async {
    if (name == 'close') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Close this session?'),
          content: const Text(
            'New uploads will stop. Accepted processing can finish before you publish.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep open'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Close session'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await action(() async {
      await services.api.send(
        'POST',
        '/v1/sessions/${widget.id}/$name',
        institute: institute,
        version: data!['session']['version'],
        mutation: Mutation(),
      );
      await load();
    });
  }

  Future<void> cancel() async {
    final reason = TextEditingController();
    await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Cancel session',
        button: 'Cancel session',
        child: TextFormField(
          controller: reason,
          decoration: const InputDecoration(labelText: 'Reason'),
          validator: requiredText,
          maxLength: 500,
        ),
        submit: (m) async {
          await services.api.send(
            'POST',
            '/v1/sessions/${widget.id}/cancel',
            institute: institute,
            version: data!['session']['version'],
            mutation: m,
            body: {'reason': reason.text.trim()},
          );
        },
      ),
    );
    reason.dispose();
    await load();
  }

  Future<void> record() => action(() async {
    capture = null;
    captureStatusRequest = null;
    captureStatusId = null;
    reserve.reset();
    complete.reset();
    recordedAt = DateTime.now().toUtc();
    await camera.initialize();
    await camera.start(const [
      'classroom',
      'classroom',
      'classroom',
      'classroom',
      'classroom',
    ]);
  });
  Future<void> upload() => action(() async {
    final file = camera.clip!;
    final bytes = await file.length();
    if (bytes > 26214400) {
      throw const AppFailure(
        'Recording exceeds 25 MiB. Retake a shorter recording.',
      );
    }
    final hash = (await sha256.bind(file.openRead()).first).toString();
    capture ??= await services.api.send(
      'POST',
      '/v1/sessions/${widget.id}/captures',
      institute: institute,
      mutation: reserve,
      body: {
        'source_type': kIsWeb ? 'webcam' : 'phone',
        'recorded_at': recordedAt!.toIso8601String(),
        'mime_type': kIsWeb ? 'video/webm' : 'video/mp4',
        'expected_bytes': bytes,
      },
    );
    Future<void> commit() async {
      await services.api.send(
        'POST',
        '/v1/captures/${capture!['id']}/upload-complete',
        institute: institute,
        mutation: complete,
        body: {
          'asset_id': capture!['asset_id'],
          'byte_size': bytes,
          'sha256': hash,
        },
      );
    }

    bool committed = false;
    if (capture!['resume_url'] != null) {
      try {
        await commit();
        committed = true;
      } on AppFailure catch (e) {
        if (e.code != 'MEDIA_NOT_AVAILABLE') {
          rethrow;
        }
      }
    }
    if (!committed) {
      final grant = await services.api.send(
        'POST',
        '/v1/captures/${capture!['id']}/upload-grant',
        institute: institute,
      );
      uploader = ResumableUpload();
      setState(() => progress = 0);
      await uploader!.upload(
        file,
        grant,
        services.config.publishableKey,
        resumeUrl: capture!['resume_url'],
        progress: (v) {
          if (mounted) setState(() => progress = v);
        },
        checkpoint: (url) async {
          capture!['resume_url'] = url;
        },
      );
      await commit();
    }
    capture!['status'] = 'queued';
    captureStatusRequest = null;
    await camera.discard();
    await camera.interrupt();
    progress = null;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Capture queued. Review suggestions after processing.'),
        ),
      );
    }
    await load();
  });
  Future<void> save(bool publish) async {
    if (publish) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Publish attendance?'),
          content: const Text(
            'Students will see these decisions. Corrections create a new publication revision.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Review again'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Publish'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await action(() async {
      await services.api.send(
        publish ? 'POST' : 'PUT',
        '/v1/sessions/${widget.id}/${publish ? 'finalize' : 'attendance-review'}',
        institute: institute,
        version: data!['session']['version'],
        mutation: Mutation(),
        body: {
          'decisions': decisions.entries
              .map((e) => {'student_id': e.key, 'status': e.value})
              .toList(),
          'acknowledge_unassessed': ack,
        },
      );
      await load();
    });
  }

  /// One-click: confirm every AI-matched student (proposed_present) as a draft
  /// Present. Deliberately leaves "Not recognized" and "Unassessed" untouched --
  /// the teacher must decide those. Reversible before publishing, so no dialog.
  void approveAllMatched() {
    final rows = (data?['items'] as List?)?.cast<Json>() ?? const <Json>[];
    setState(() {
      for (final row in rows) {
        final value = decisions[row['student_id']] ?? row['status'];
        if (value == 'proposed_present') {
          decisions[row['student_id']] = 'present';
        }
      }
      syncExitGuard();
    });
  }

  Future<void> correct(Json row) async {
    String status = row['status'];
    final reason = TextEditingController();
    await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Correct published attendance',
        button: 'Publish correction',
        child: Column(
          children: [
            Text(row['official_name']),
            DropdownButtonFormField<String>(
              initialValue: status,
              items: [
                'present',
                'absent',
                'late',
                'excused',
                'unassessed',
              ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => status = v!,
            ),
            TextFormField(
              controller: reason,
              validator: requiredText,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Correction reason'),
            ),
          ],
        ),
        submit: (m) async {
          await services.api.send(
            'POST',
            '/v1/sessions/${widget.id}/corrections',
            institute: institute,
            version: data!['session']['version'],
            mutation: m,
            body: {
              'student_id': row['student_id'],
              'status': status,
              'reason': reason.text.trim(),
              'publication_revision': data!['session']['attendance_revision'],
            },
          );
        },
      ),
    );
    reason.dispose();
    await load();
  }

  @override
  void dispose() {
    loadGeneration++;
    exitGuard.leave(widget.id);
    poll?.cancel();
    lifecycle?.dispose();
    uploader?.cancel();
    camera.removeListener(changed);
    unawaited(camera.discard());
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return ContentPage(
        children: [
          if (error != null)
            ErrorView(error!, retry: load)
          else
            const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    final s = data!['session'] as Json;
    final rows = (data!['items'] as List).cast<Json>();
    final finalised = s['status'] == 'finalized';
    final hasUnconfirmedProposal = rows.any(
      (row) => [
        'proposed_present',
        'proposed_absent',
      ].contains(decisions[row['student_id']] ?? row['status']),
    );
    final editable = ![
      'scheduled',
      'cancelled',
      'finalized',
    ].contains(s['status']);
    return ContentPage(
      children: [
        TextButton.icon(
          onPressed: () => context.go('/classes/${s['offering_id']}'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back to subject'),
        ),
        PageHeader(
          compact: true,
          title: 'Attendance session',
          subtitle:
              '${sessionDate(context, s['starts_at'])} · ${sessionLabel(s['status'])}',
          eyebrow: 'SESSION WORKSPACE',
          icon: Icons.videocam_outlined,
          action: OutlinedButton(
            onPressed: busy ? null : refreshWithConfirmation,
            child: const Text('Refresh'),
          ),
        ),
        if (error != null) ...[
          if (decisions.isNotEmpty)
            const Text(
              'Refreshing will discard choices that were not saved. Review each student again before publishing.',
            ),
          Semantics(
            liveRegion: true,
            child: ErrorView(error!, retry: refreshWithConfirmation),
          ),
        ],
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s['status'] == 'open'
                    ? 'After the final capture finishes processing, close this session. Then review each student and publish attendance. Saving decisions while open only saves a draft.'
                    : 'Open to freeze the roster, capture the classroom, then review and publish. Students not recognized start as Absent for you to check; students who could not be assessed stay unassessed.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (s['status'] == 'scheduled')
                    FilledButton(
                      onPressed: busy ? null : () => transition('open'),
                      child: const Text('Open session'),
                    ),
                  if (s['status'] == 'open')
                    OutlinedButton(
                      onPressed: busy ? null : () => transition('close'),
                      child: const Text('Close session'),
                    ),
                  if (['scheduled', 'open'].contains(s['status']))
                    TextButton(
                      onPressed: busy ? null : cancel,
                      child: const Text('Cancel session'),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (s['status'] == 'open')
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Classroom capture',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text(
                  'Use good lighting and walk slowly so each face is large and steady for a few seconds. Recording lasts 15 seconds with audio off. For a larger class, record two or three clips, each covering part of the room: every clip adds recognized students. Keep this page open until upload completes.',
                ),
                if (camera.controller != null && camera.clip == null)
                  AspectRatio(
                    aspectRatio: camera.controller!.value.aspectRatio,
                    child: camera.controller!.buildPreview(),
                  ),
                if (camera.error != null) Text(camera.error!),
                if (camera.recording)
                  Text('Recording ${camera.elapsed} / 15 seconds'),
                if (camera.clip != null) ...[
                  ClipPlayback(file: camera.clip!),
                  if (progress != null)
                    LinearProgressIndicator(value: progress),
                  FilledButton(
                    onPressed: busy ? null : upload,
                    child: Text(
                      busy ? 'Uploading…' : 'Upload classroom capture',
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => camera.discard(),
                    child: const Text('Retake recording'),
                  ),
                ] else if (!camera.recording)
                  FilledButton.icon(
                    onPressed: busy ? null : record,
                    icon: const Icon(Icons.videocam_outlined),
                    label: const Text('Record classroom'),
                  ),
              ],
            ),
          ),
        if (capture != null)
          FutureBuilder<Json>(
            future: captureStatus(capture!['id'] as String),
            builder: (c, snapshot) => Text(
              snapshot.hasData
                  ? 'Capture: ${captureStatusLabel(snapshot.data!['status'] as String)}'
                  : snapshot.hasError
                  ? 'Capture status unavailable. Refresh this session to retry.'
                  : 'Checking capture status…',
            ),
          ),
        if (rows.isEmpty)
          const Panel(
            child: Text(
              'No students on this roster. Approve subject membership before opening a new session.',
            ),
          )
        else
          AttendanceReviewTable(
            rows: rows,
            decisions: decisions,
            editable: editable,
            finalised: finalised,
            busy: busy,
            sessionLabel: sessionLabel(s['status']),
            onChanged: (id, status) => setState(() {
              decisions[id] = status;
              syncExitGuard();
            }),
            onApproveAllMatched: approveAllMatched,
            onCorrect: correct,
          ),
        if (editable) ...[
          if (s['status'] != 'open' &&
              rows.any(
                (row) =>
                    row['status'] == 'proposed_absent' &&
                    decisions[row['student_id']] == 'absent',
              ))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${rows.where((row) => row['status'] == 'proposed_absent' && decisions[row['student_id']] == 'absent').length} '
                'students not recognized are set to Absent. Change anyone who was actually present before publishing.',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          if (hasUnconfirmedProposal && s['status'] != 'open')
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Resolve every matched and not-recognized row before publishing. Use the filters above to find them quickly.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (s['status'] != 'open')
            CheckboxListTile(
              value: ack,
              onChanged: (v) => setState(() => ack = v ?? false),
              title: const Text(
                'I understand that any unassessed students make this publication incomplete.',
              ),
            ),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => save(false),
                child: const Text('Save draft decisions'),
              ),
              if (s['status'] != 'open')
                FilledButton(
                  onPressed: busy || hasUnconfirmedProposal
                      ? null
                      : () => save(true),
                  child: const Text('Publish attendance'),
                ),
            ],
          ),
        ],
        if (finalised)
          Panel(
            child: Text(
              'Published revision ${s['attendance_revision']}. Students can view their own attendance.',
            ),
          ),
        if (!['scheduled', 'open', 'cancelled'].contains(s['status']))
          TeacherReports(
            api: services.api,
            institute: institute,
            sessionId: widget.id,
            supabaseUrl: services.config.supabaseUrl,
            sessionVersion: s['version'] as int,
          ),
      ],
    );
  }
}

bool _captureIsPending(Object? status) =>
    const {'awaiting_upload', 'queued', 'processing'}.contains(status);

String captureStatusLabel(String status) => switch (status) {
  'awaiting_upload' => 'waiting for upload',
  'queued' => 'waiting for processing',
  'processing' => 'processing video',
  'review_required' => 'ready for attendance review',
  'failed' => 'processing failed — review manually',
  'expired' => 'upload expired',
  _ => status.replaceAll('_', ' '),
};
