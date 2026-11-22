import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:crypto/crypto.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'attendance_table.dart';
import 'classroom_scan.dart';
import 'classroom_pending.dart';
import 'processing_progress.dart';
import 'recognition_board.dart';
import 'review_card.dart' show initialsOf;
import 'scan_quality.dart';
import 'teacher_timetable.dart';
import 'teacher_reports.dart';
import 'unload_warning.dart';

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
    this.version = 0,
    this.changed,
    this.onAccessLost,
  });
  final ApiClient api;
  final String institute, offering, publishableKey;

  /// A change reloads the list (the subject page's refresh).
  final int version;

  /// Called after sessions were created or imported.
  final VoidCallback? changed;
  final ValueChanged<Object>? onAccessLost;
  @override
  State<TeacherSessions> createState() => _TeacherSessionsState();
}

/// Which sessions a filter shows.
enum SessionGroup { todo, upcoming, published, cancelled }

SessionGroup sessionGroup(Json s) => switch (s['status']) {
  'scheduled' => SessionGroup.upcoming,
  'finalized' => SessionGroup.published,
  'cancelled' => SessionGroup.cancelled,
  _ => SessionGroup.todo, // open, closed, review_required, no_data
};

class _TeacherSessionsState extends State<TeacherSessions> {
  List<Json>? sessions;
  Object? error;
  bool loading = false;
  SessionGroup? filter;
  int _generation = 0;
  String? cursor;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(TeacherSessions old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) load();
  }

  Future<void> load({bool append = false}) async {
    final generation = ++_generation;
    final next = append ? cursor : null;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = PageData.fromJson(
        await ApiClient.freshReads(
          () => widget.api.send(
            'GET',
            '/v1/sessions',
            institute: widget.institute,
            query: {
              'offering_id': widget.offering,
              'group': ?filter?.name,
              'cursor': ?next,
            },
          ),
        ),
        (row) => row,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        sessions = [if (append) ...?sessions, ...page.items];
        cursor = page.nextCursor;
        loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      final denied =
          e is AppFailure && const {401, 403, 404}.contains(e.status);
      if (denied) widget.onAccessLost?.call(e);
      setState(() {
        if (denied) {
          sessions = null;
          cursor = null;
        }
        error = e;
        loading = false;
      });
    }
  }

  void selectGroup(SessionGroup? next) {
    if (filter == next) return;
    setState(() {
      filter = next;
      sessions = null;
      cursor = null;
    });
    load();
  }

  Future<void> create() async {
    final room = TextEditingController();
    DateTime start = DateTime.now();
    int minutes = 60;
    final saved = await showDialog<bool>(
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
    disposeAfterDialog(room);
    if (saved == true && mounted) {
      await load();
      if (mounted) widget.changed?.call();
    }
  }

  Future<void> importTimetable() async {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final body = SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Import timetable',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Upload the timetable CSV, check the preview, then confirm to create the scheduled sessions.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TeacherTimetable(
            api: widget.api,
            institute: widget.institute,
            offering: widget.offering,
            publishableKey: widget.publishableKey,
            changed: () {
              load();
              widget.changed?.call();
            },
          ),
        ],
      ),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => narrow
          ? Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  leading: IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                body: body,
              ),
            )
          : Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 720,
                  maxHeight: 760,
                ),
                child: Stack(
                  children: [
                    body,
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  static const _groupInfo = {
    SessionGroup.todo: (
      'Needs your action',
      'Open, closed or waiting for your review',
    ),
    SessionGroup.upcoming: ('Upcoming', 'Scheduled and not yet opened'),
    SessionGroup.published: ('Published', 'Attendance students can see'),
    SessionGroup.cancelled: ('Cancelled', 'Kept for the record'),
  };

  @override
  Widget build(BuildContext context) {
    final all = sessions ?? const <Json>[];
    final groups = {for (final g in SessionGroup.values) g: <Json>[]};
    for (final s in all) {
      groups[sessionGroup(s)]!.add(s);
    }
    int byStart(Json a, Json b) =>
        (a['starts_at'] as String).compareTo(b['starts_at'] as String);
    groups[SessionGroup.todo]!.sort(byStart);
    groups[SessionGroup.upcoming]!.sort(byStart);
    groups[SessionGroup.published]!.sort((a, b) => byStart(b, a));
    groups[SessionGroup.cancelled]!.sort((a, b) => byStart(b, a));

    final Widget list;
    if (sessions == null && error == null) {
      list = const SkeletonList();
    } else if (error != null && sessions == null) {
      list = ErrorView(error!, retry: load);
    } else if (all.isEmpty) {
      list = MessageView(
        icon: Icons.event_note_outlined,
        title: filter == null ? 'No sessions yet' : 'No sessions in this group',
        message: filter == null
            ? 'Use Create session above to start taking attendance for your next class, or import your timetable to schedule sessions in bulk.'
            : 'Choose All to see every session for this subject.',
      );
    } else {
      final shown = [
        for (final g in SessionGroup.values)
          if ((filter == null || filter == g) && groups[g]!.isNotEmpty) g,
      ];
      list = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No sessions in this group.')),
            ),
          for (final g in shown) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 10),
              child: Wrap(
                spacing: 0,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _groupInfo[g]!.$1,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${groups[g]!.length} · ${_groupInfo[g]!.$2}',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            for (final (i, s) in groups[g]!.indexed)
              Reveal(
                key: ValueKey(s['id']),
                delayMs: i < 8 ? i * 30 : 0,
                child: SessionCard(
                  session: s,
                  onReturn: () {
                    if (!mounted) return;
                    load();
                    widget.changed?.call();
                  },
                ),
              ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('Create session'),
            ),
            OutlinedButton.icon(
              onPressed: importTimetable,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Import timetable'),
            ),
          ],
        ),
        // Nothing to filter until the subject has at least one session.
        if (filter != null || all.isNotEmpty || cursor != null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: filter == null,
                onSelected: (_) => selectGroup(null),
              ),
              for (final g in SessionGroup.values)
                ChoiceChip(
                  label: Text(_groupInfo[g]!.$1),
                  selected: filter == g,
                  onSelected: (_) => selectGroup(g),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        if (loading && sessions != null)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(semanticsLabel: 'Refreshing sessions'),
          ),
        if (error != null && sessions != null) ErrorView(error!, retry: load),
        list,
        if (cursor != null)
          TextButton(
            onPressed: loading ? null : () => load(append: true),
            child: const Text('Load older sessions'),
          ),
      ],
    );
  }
}

/// One session: a calendar tile, time and room, its state and the next step.
class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.session, this.onReturn});
  final Json session;
  final VoidCallback? onReturn;

  static (Color, IconData) style(String? status) => switch (status) {
    'scheduled' => (const Color(0xff465650), Icons.event_outlined),
    'open' => (const Color(0xff1f5fa8), Icons.videocam_outlined),
    'review_required' => (const Color(0xff9a6a00), Icons.rate_review_outlined),
    'no_data' => (const Color(0xff9a6a00), Icons.edit_note),
    'finalized' => (const Color(0xff176451), Icons.verified_outlined),
    'cancelled' => (const Color(0xff7a7f7d), Icons.event_busy_outlined),
    _ => (const Color(0xff9a6a00), Icons.lock_clock_outlined), // closed
  };

  @override
  Widget build(BuildContext context) {
    final s = session, scheme = Theme.of(context).colorScheme;
    final l = MaterialLocalizations.of(context);
    final start = DateTime.parse(s['starts_at'] as String).toLocal();
    final end = s['ends_at'] is String
        ? DateTime.parse(s['ends_at'] as String).toLocal()
        : null;
    final status = s['status'] as String?;
    final (color, icon) = style(status);
    final room = (s['room_label'] as String?) ?? '';
    final action = switch (status) {
      'finalized' => 'View attendance',
      'review_required' || 'no_data' || 'closed' => 'Review attendance',
      'open' => 'Continue capture',
      'cancelled' => 'View',
      _ => 'Open session',
    };
    final primary = sessionGroup(s) == SessionGroup.todo;
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    Future<void> open() async {
      await context.push('/sessions/${s['id']}');
      if (context.mounted) onReturn?.call();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: open,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: primary
                    ? color.withValues(alpha: .45)
                    : scheme.outlineVariant,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final narrow = box.maxWidth < 460;
                final button = primary
                    ? FilledButton(onPressed: open, child: Text(action))
                    : TextButton(onPressed: open, child: Text(action));
                final row = Row(
                  children: [
                    Container(
                      width: 58,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Text(
                            months[start.month - 1],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: color,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            '${start.day}',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: color,
                              height: 1.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${l.formatTimeOfDay(TimeOfDay.fromDateTime(start))}'
                            '${end == null ? '' : ' – ${l.formatTimeOfDay(TimeOfDay.fromDateTime(end))}'}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: .10),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(icon, size: 14, color: color),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        sessionLabel(status ?? ''),
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: color,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (room.isNotEmpty)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.meeting_room_outlined,
                                      size: 15,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      room,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              Text(
                                l.formatMediumDate(start),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!narrow) ...[const SizedBox(width: 8), button],
                  ],
                );
                if (!narrow) return row;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [row, const SizedBox(height: 10), button],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
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

  /// The session's subject, for the banner; loaded once.
  Offering? offering;
  AppFailure? error;

  /// Record/upload problems, shown inside the capture panel next to the
  /// button rather than at the top of the page.
  AppFailure? captureError;
  bool busy = false, scanActive = false;
  final scanUploads = <String, _ScanUpload>{};
  ClassroomPending? scanStore;
  int webPreviewTurns = 0;
  final decisions = <String, String>{};
  final camera = GuidedCamera(
    analyzerFactory:
        !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS)
        ? (controller) => createDeviceFaceAnalyzer(controller, classroom: true)
        : null,
  );
  ResumableUpload? uploader;
  double? progress;
  Json? capture;
  Future<Json>? captureStatusRequest;
  String? captureStatusId;
  DateTime? recordedAt;
  late final SessionExitGuard exitGuard;
  final reserve = Mutation(), complete = Mutation();
  Timer? poll;
  bool foreground = true;
  AppLifecycleListener? lifecycle;
  int loadGeneration = 0;

  /// When the app left the screen during a scan (for the diagnostics timeline).
  DateTime? pausedAt;
  void _notePaused(String why) {
    if (!scanActive || pausedAt != null) return;
    pausedAt = DateTime.now();
    services.diagnostics.record('scan_paused', sessionId: widget.id, code: why);
  }

  @override
  void initState() {
    super.initState();
    services = ref.read(servicesProvider);
    institute = ref.read(authProvider).institute!;
    exitGuard = ref.read(sessionExitGuardProvider)..enter(widget.id);
    camera.addListener(changed);
    camera.onEvent = (name, {code}) =>
        services.diagnostics.record(name, sessionId: widget.id, code: code);
    lifecycle = AppLifecycleListener(
      onHide: () {
        foreground = false;
        poll?.cancel();
        _notePaused('hidden');
      },
      onPause: () {
        foreground = false;
        poll?.cancel();
        _notePaused('paused');
        if (!scanActive) unawaited(camera.interrupt());
      },
      onResume: () {
        foreground = true;
        final since = pausedAt;
        if (since != null) {
          pausedAt = null;
          services.diagnostics.record(
            'scan_resumed',
            sessionId: widget.id,
            code: 'resumed',
            seconds: DateTime.now().difference(since).inMilliseconds / 1000,
          );
        }
        unawaited(load(keepDecisions: true));
      },
    );
    load();
  }

  void changed() {
    if (mounted) setState(() {});
    if (!scanActive && camera.clip != null && camera.ready && !camera.busy) {
      unawaited(camera.interrupt());
    }
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
      if (sessionStatus != 'open' && !processingPending) {
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
    setUnloadWarning(exitGuard.dirty);
  }

  Future<void> _loadOffering(String id) async {
    try {
      final o = await services.api.offering(institute, id);
      if (mounted) setState(() => offering = o);
    } catch (_) {
      // The banner falls back to "Attendance session".
    }
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

  /// One idempotency key per session action, reused if a retry follows a
  /// lost response and renewed after success.
  final _mutations = <String, Mutation>{};
  Mutation _mutation(String action) =>
      _mutations.putIfAbsent(action, Mutation.new);

  /// Polls while the session is open or a capture is processing, also after
  /// a failed or skipped refresh, so the page never stops updating.
  bool get processingPending =>
      data?['processing_pending'] as bool? ??
      _captureIsPending(capture?['status']);

  /// How soon to look again: quickly only while something is being processed or a scan is
  /// running, slowly while the session is merely open, never while the app is in the background.
  Duration get pollInterval =>
      processingPending || scanActive
      ? const Duration(seconds: 5)
      : const Duration(seconds: 15);

  void _schedulePoll({bool failed = false}) {
    poll?.cancel();
    if (!mounted || !foreground) return;
    if (data?['session']?['status'] == 'open' || processingPending) {
      poll = Timer(
        failed ? const Duration(seconds: 15) : pollInterval,
        () => load(keepDecisions: true, conditional: true),
      );
    }
  }

  /// [keepDecisions] re-applies unsaved choices over the fresh rows (after an
  /// upload or close); a saved draft or [discardChanges] starts clean.
  Future<void> load({
    bool discardChanges = false,
    bool keepDecisions = false,
    bool conditional = false,
  }) async {
    if (decisions.isNotEmpty && !busy && !discardChanges && !keepDecisions) {
      _schedulePoll();
      return;
    }
    final current = ++loadGeneration;
    try {
      final result = await services.api.send(
        'GET',
        '/v1/sessions/${widget.id}/attendance',
        institute: institute,
        query: {
          if (conditional && data?['session']?['version'] is int) ...{
            'known_version': data!['session']['version'],
            'known_processing': processingPending,
          },
        },
      );
      if (!mounted || current != loadGeneration) return;
      if (result['unchanged'] == true) {
        if (error != null) setState(() => error = null);
        _schedulePoll();
        return;
      }
      final kept = keepDecisions ? Map.of(decisions) : const <String, String>{};
      if (offering == null) {
        _loadOffering(result['session']['offering_id'] as String);
      }
      setState(() {
        data = result;
        error = null;
        decisions.clear();
        // Pre-fill only once processing is over, so polling keeps refreshing
        // while a capture is still running.
        if (const {
              'closed',
              'review_required',
              'no_data',
            }.contains(result['session']['status']) &&
            !processingPending) {
          decisions.addAll(
            draftScanDecisions((result['items'] as List).cast<Json>()),
          );
        }
        final onRoster = {
          for (final row in (result['items'] as List).cast<Json>())
            row['student_id'],
        };
        kept.forEach((id, status) {
          if (onRoster.contains(id)) decisions[id] = status;
        });
        syncExitGuard();
        captureStatusRequest = null;
      });
      _schedulePoll();
    } catch (e) {
      if (mounted && current == loadGeneration) {
        services.diagnostics.record(
          'recognition_load_failed',
          sessionId: widget.id,
          route: '/v1/sessions/${widget.id}/attendance',
          status: e is AppFailure ? e.status : null,
          code: e is AppFailure ? e.code : null,
        );
        setState(
          () => error = e is AppFailure
              ? e
              : const AppFailure('Could not load this session. Retry.'),
        );
        // Access lost or session gone: polling again cannot help; the error has a Retry.
        final denied = e is AppFailure && const {401, 403, 404}.contains(e.status);
        if (denied) {
          poll?.cancel();
          poll = null;
        } else {
          _schedulePoll(failed: true);
        }
      }
    }
  }

  Future<void> action(
    Future<void> Function() fn, {
    bool capturePanel = false,
  }) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      if (capturePanel) captureError = null;
    });
    exitGuard.busy = true;
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        final failure = e is AppFailure
            ? e
            : const AppFailure(
                'The action did not finish. Retry without leaving this page.',
              );
        setState(() {
          if (capturePanel) {
            progress = null;
            captureError = failure;
          } else {
            error = failure;
          }
        });
        if (capturePanel) showMessage(context, failure.message);
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
          title: const Text('Finish recording and review?'),
          content: const Text(
            'Finish adding recordings first. Processing can continue while you review attendance.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep open'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Go to review'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await action(() async {
      // Recordings and their results keep bumping the session's version in the background. A
      // version read before the last segment finished made "close" fail with VERSION_CONFLICT,
      // so ask for the current one first.
      if (name == 'close') await load(keepDecisions: true);
      await services.api.send(
        'POST',
        '/v1/sessions/${widget.id}/$name',
        institute: institute,
        version: data!['session']['version'],
        mutation: _mutation(name),
      );
      _mutation(name).reset();
      if (name == 'close') await camera.interrupt();
      await load(keepDecisions: true);
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
    disposeAfterDialog(reason);
    await load();
    if (mounted && data?['session']['status'] == 'cancelled') {
      await camera.interrupt();
    }
  }

  Future<RecognitionSnapshot> scanResults() async {
    final result = await services.api.send(
      'GET',
      '/v1/sessions/${widget.id}/attendance',
      institute: institute,
    );
    return RecognitionSnapshot(
      (result['items'] as List).cast<Json>(),
      processing: result['processing_pending'] == true,
      info: ProcessingInfo.fromJson(result['processing']),
    );
  }

  Future<void> uploadScanSegment(
    XFile file, {
    void Function(String, [double?])? report,
  }) async {
    report?.call('Preparing recording…');
    final state = scanUploads.putIfAbsent(file.path, _ScanUpload.new);
    final bytes = await file.length();
    if (bytes == 0 || bytes > 26214400) {
      throw const AppFailure(
        'Captured segment is empty or exceeds 25 MiB. Choose a shorter segment length and record again.',
        code: 'CAPTURE_SIZE',
      );
    }
    final hash = (await sha256.bind(file.openRead()).first).toString();
    for (var attempt = 0; state.capture == null; attempt++) {
      if (!mounted) throw const AppFailure('Session closed.');
      try {
        state.capture = await services.api.send(
          'POST',
          '/v1/sessions/${widget.id}/captures',
          institute: institute,
          mutation: state.reserve,
          body: {
            'source_type': kIsWeb ? 'webcam' : 'phone',
            'recorded_at': state.recordedAt.toIso8601String(),
            'mime_type': kIsWeb ? 'video/webm' : 'video/mp4',
            'expected_bytes': bytes,
          },
        );
        await scanStore?.update(file.path, state.toJson());
      } on AppFailure catch (e) {
        if (e.code != 'CAPTURE_LIMIT' || attempt >= 23) rethrow;
        report?.call('Waiting for an upload slot…');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    final current = state.capture!;
    Future<void> commit() async {
      if (!mounted) throw const AppFailure('Session closed.');
      report?.call('Verifying upload…');
      await services.api.send(
        'POST',
        '/v1/captures/${current['id']}/upload-complete',
        institute: institute,
        mutation: state.complete,
        body: {
          'asset_id': current['asset_id'],
          'byte_size': bytes,
          'sha256': hash,
        },
      );
    }

    bool committed = false;
    if (state.resumeUrl != null) {
      try {
        await commit();
        committed = true;
      } on AppFailure catch (e) {
        if (e.code != 'MEDIA_NOT_AVAILABLE') rethrow;
        state.uploaded = false;
      }
    }
    if (!committed) {
      if (!state.uploaded) {
        if (!mounted) throw const AppFailure('Session closed.');
        final grant = await services.api.send(
          'POST',
          '/v1/captures/${current['id']}/upload-grant',
          institute: institute,
        );
        if (!mounted) throw const AppFailure('Session closed.');
        uploader = ResumableUpload();
        await uploader!.upload(
          file,
          grant,
          services.config.publishableKey,
          resumeUrl: state.resumeUrl,
          progress: (value) => report?.call('Uploading recording…', value),
          checkpoint: (url) async {
            state.resumeUrl = url;
            await scanStore?.update(file.path, state.toJson());
          },
        );
        state.uploaded = true;
        await scanStore?.update(file.path, state.toJson());
      }
      await commit();
    }
    if (!mounted) return;
    capture = {...current, 'status': 'queued'};
    captureStatusId = null;
    captureStatusRequest = null;
    scanUploads.remove(file.path);
  }

  Future<ClassroomPending> _openScanStore() async {
    final owner = services.client.auth.currentUser?.id;
    if (owner == null) throw const AppFailure('Sign in again before scanning.');
    return scanStore = ClassroomPending(owner, institute, widget.id);
  }

  Future<void> openClassroomScan() async {
    if (scanActive || busy || camera.recording || camera.clip != null) return;
    setState(() => scanActive = true);
    ClassroomScan? scan;
    try {
      await camera.interrupt();
      if (!mounted) return;
      // Phones keep unsent segments on disk so a crash or a closed app can resume; a browser has
      // no private storage for video, so it holds them in memory and warns before the tab closes.
      final store = kIsWeb ? null : await _openScanStore();
      final recovered = store == null ? const <Map<String, dynamic>>[] : await store.load();
      for (final entry in recovered) {
        scanUploads[entry['path'] as String] = _ScanUpload.fromJson(
          (entry['upload'] as Map).cast<String, dynamic>(),
        );
      }
      scan = ClassroomScan(
        camera,
        (file) => uploadScanSegment(file, report: scan!.reportUpload),
        retain: store == null
            ? null
            : (file) async {
                final state = _ScanUpload();
                final saved = await store.retain(file, state.toJson());
                scanUploads[saved.path] = state;
                return saved;
              },
        remove: store == null ? null : (file) => store.remove(file.path),
        recovered: [for (final entry in recovered) XFile(entry['path'] as String)],
        onEvent: (name, {code, attempt, bytes, count, durationMs}) =>
            services.diagnostics.record(
              name,
              sessionId: widget.id,
              code: code,
              attempt: attempt,
              bytes: bytes,
              count: count,
              durationMs: durationMs,
            ),
      );
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) =>
              ClassroomScanPage(
                scan: scan!,
                results: scanResults,
                reference: widget.id.substring(0, 8),
              ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => captureError = e is AppFailure
              ? e
              : const AppFailure(
                  'Camera scan could not continue. Please retry.',
                ),
        );
      }
    } finally {
      scan?.dispose();
      scanUploads.clear();
      scanStore = null;
      if (mounted) await camera.interrupt();
      if (mounted) {
        setState(() => scanActive = false);
        await load(keepDecisions: true);
      }
    }
  }

  Future<void> record() => action(capturePanel: true, () async {
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
  Future<void> upload() => action(capturePanel: true, () async {
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
      if (!mounted) return;
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
    if (mounted) {
      setState(() => progress = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Capture queued. Review suggestions after processing.'),
        ),
      );
    }
    await load(keepDecisions: true);
  });
  Future<void> save(bool publish) async {
    await action(() async {
      await services.api.send(
        publish ? 'POST' : 'PUT',
        '/v1/sessions/${widget.id}/${publish ? 'finalize' : 'attendance-review'}',
        institute: institute,
        version: data!['session']['version'],
        mutation: _mutation(publish ? 'publish' : 'draft'),
        body: {
          'decisions': decisions.entries
              .map((e) => {'student_id': e.key, 'status': e.value})
              .toList(),
        },
      );
      _mutation(publish ? 'publish' : 'draft').reset();
      await load();
    });
  }

  /// Confirm suggested Present marks. Other rows retain their current choice.
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
    // Older publications may hold late/excused; offer the folded state.
    final original = finalStatus(row['status'] as String?);
    String? status = finalStatuses.contains(original) ? original : null;
    final reason = TextEditingController();
    await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Correct published attendance',
        button: 'Publish correction',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              row['official_name'] as String? ?? 'Student',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: status,
              decoration: const InputDecoration(labelText: 'Attendance'),
              items: [
                for (final s in finalStatuses)
                  DropdownMenuItem(value: s, child: Text(attendanceLabel(s))),
              ],
              validator: (v) => v == null ? 'Choose Present or Absent' : null,
              onChanged: (v) => status = v,
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
    disposeAfterDialog(reason);
    await load();
  }

  @override
  void dispose() {
    loadGeneration++;
    // Only while this page still owns the guard: a notice can open another session page whose
    // initState has already armed the prompt for its own unsaved marks.
    if (exitGuard.protects(widget.id)) setUnloadWarning(false);
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
          else ...const [SkeletonCard(), SkeletonList()],
        ],
      );
    }
    final s = data!['session'] as Json;
    final rows = (data!['items'] as List).cast<Json>();
    final finalised = s['status'] == 'finalized';
    final editable = ![
      'open',
      'scheduled',
      'cancelled',
      'finalized',
    ].contains(s['status']);
    final status = s['status'] as String;
    final canRecord =
        rows
            .where((row) => row['recognition_eligible'] == true)
            .take(2)
            .length ==
        2;
    final captured =
        capture != null ||
        rows.any(
          (row) =>
              row['assessment_code'] != null &&
              row['assessment_code'] != 'template_ineligible',
        );
    final counts = DecisionCounts.of(rows, decisions);
    final page = ContentPage(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => goBack(context, '/classes/${s['offering_id']}'),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to subject'),
          ),
        ),
        _SessionHero(
          session: s,
          offering: offering,
          onRefresh: busy ? null : refreshWithConfirmation,
        ),
        const SizedBox(height: 16),
        if (error != null) ...[
          if (decisions.isNotEmpty)
            const Text(
              'Refreshing will discard choices that were not saved. Review each student again before publishing.',
            ),
          Semantics(
            liveRegion: true,
            child: ErrorView(error!, retry: refreshWithConfirmation),
          ),
          const SizedBox(height: 16),
        ],
        Panel(
          padding: MediaQuery.sizeOf(context).width < 600 ? 16 : 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SessionSteps(status: status, captured: captured),
              const SizedBox(height: AppSpace.sm),
              Text(
                sessionStepHint(status, captured: captured),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (['scheduled', 'open'].contains(status)) ...[
                const SizedBox(height: AppSpace.lg),
                _StepActions(
                  children: [
                    if (status == 'scheduled')
                      FilledButton.icon(
                        onPressed: busy ? null : () => transition('open'),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Open session'),
                      ),
                    if (status == 'open')
                      (captured ? FilledButton.icon : OutlinedButton.icon)(
                        onPressed:
                            busy ||
                                camera.busy ||
                                camera.recording ||
                                scanActive ||
                                camera.clip != null
                            ? null
                            : () => transition('close'),
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Go to review'),
                      ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: busy || camera.busy || camera.recording
                          ? null
                          : cancel,
                      child: const Text('Cancel session'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (status == 'open') ...[
          Panel(
            padding: MediaQuery.sizeOf(context).width < 600 ? 16 : 24,
            child: Column(
              key: const ValueKey('capture-panel'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PanelHeading(
                  icon: Icons.videocam_outlined,
                  title: 'Classroom capture',
                  subtitle: canRecord
                      ? 'Scan the room with the camera. Clips upload while you scan.'
                      : null,
                ),
                const SizedBox(height: AppSpace.md),
                if (canRecord) ...[
                  TonePill(
                    '${rows.where((r) => r['recognition_eligible'] == true).length} of ${rows.length} students can be recognised',
                    tone: AppTone.info,
                    icon: Icons.face_outlined,
                  ),
                  const SizedBox(height: AppSpace.md),
                  const _HowItWorks(
                    steps: [
                      'Open the camera, then tap Start scan.',
                      'Move slowly across the room and pause on each group.',
                      'Tap Stop scan when finished. Keep this page open while the clips upload.',
                    ],
                  ),
                ] else
                  const _Callout(
                    icon: Icons.person_off_outlined,
                    tone: AppTone.warning,
                    text:
                        'This session needs at least two students with approved face enrolments. Go to review to mark attendance manually, or open a new session after two enrolments are approved.',
                  ),
                const SizedBox(height: AppSpace.lg),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed:
                        !canRecord ||
                            busy ||
                            camera.busy ||
                            scanActive ||
                            camera.recording ||
                            camera.clip != null
                        ? null
                        : openClassroomScan,
                    icon: const Icon(Icons.videocam_outlined),
                    label: const Text('Scan classroom'),
                  ),
                ),
                if (canRecord)
                  ExpansionTile(
                    title: const Text('Recording tips'),
                    children: const [RecordingTips()],
                  ),
                if (captureCoverage(rows) case final coverage?)
                  CaptureQualityNote(coverage),
                ExpansionTile(
                  enabled: canRecord || camera.clip != null,
                  title: const Text('Record a single clip'),
                  children: [
                    if (camera.cameras.length > 1 && camera.clip == null)
                      DropdownButtonFormField<String>(
                        key: ValueKey(camera.selectedCamera?.name),
                        initialValue: camera.selectedCamera?.name,
                        decoration: const InputDecoration(labelText: 'Camera'),
                        items: [
                          for (final device in camera.cameras)
                            DropdownMenuItem(
                              value: device.name,
                              child: Text(
                                '${device.lensDirection.name} · ${device.name}',
                              ),
                            ),
                        ],
                        onChanged: busy || camera.busy || camera.recording
                            ? null
                            : (name) {
                                for (final device in camera.cameras) {
                                  if (device.name == name) {
                                    camera.selectCamera(device);
                                    break;
                                  }
                                }
                              },
                      ),
                    if (!scanActive &&
                        camera.controller != null &&
                        camera.clip == null) ...[
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth.clamp(0.0, 720.0);
                          final height = (width * .6).clamp(220.0, 420.0);
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: SizedBox(
                                width: width,
                                height: height,
                                child: ColoredBox(
                                  color: Colors.black,
                                  child: ListenableBuilder(
                                    listenable: camera.faceTracker,
                                    builder: (context, _) => RotatedBox(
                                      quarterTurns: kIsWeb
                                          ? webPreviewTurns
                                          : 0,
                                      child: LiveCameraPreview(
                                        camera: camera.controller!,
                                        faces: camera.faceTracker.faces,
                                        onFocus: (point) =>
                                            unawaited(camera.focus(point)),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      if (camera.controller!.value.focusPointSupported)
                        const Text('Tap the preview to focus.'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (kIsWeb)
                            TextButton.icon(
                              onPressed: () => setState(
                                () =>
                                    webPreviewTurns = (webPreviewTurns + 1) % 4,
                              ),
                              icon: const Icon(Icons.rotate_right),
                              label: const Text('Rotate preview'),
                            ),
                          if (!kIsWeb)
                          TextButton.icon(
                            onPressed: camera.busy ? null : camera.toggleTorch,
                            icon: const Icon(Icons.flashlight_on),
                            label: Text(
                              camera.controller!.value.flashMode ==
                                      FlashMode.torch
                                  ? 'Turn torch off'
                                  : 'Turn torch on',
                            ),
                          ),
                          if (!camera.recording)
                            TextButton(
                              onPressed: camera.busy ? null : camera.interrupt,
                              child: const Text('Close camera'),
                            ),
                        ],
                      ),
                      if (camera.controlMessage != null)
                        Text(camera.controlMessage!),
                      if (camera.recording)
                        ListenableBuilder(
                          listenable: camera.faceTracker,
                          builder: (context, _) => Text(
                            camera.faceTracker.available
                                ? camera.faceTracker.faces.isEmpty
                                      ? 'No faces in view. Aim the camera toward the class.'
                                      : 'Grey outlines are detected faces; amber means move closer. Names turn green only after the server recognises them.'
                                : 'Live face guidance is currently unavailable. Recording continues.',
                          ),
                        ),
                    ],
                    if (camera.error != null) Text(camera.error!),
                    if (camera.recording)
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTone.tint(AppTone.danger, .08),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.fiber_manual_record,
                                color: Color(0xffc62828),
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Recording ${camera.elapsed} / 15 seconds',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (camera.clip != null) ...[
                      ClipPlayback(file: camera.clip!),
                      if (progress != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(value: progress),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: busy ? null : upload,
                            icon: const Icon(Icons.cloud_upload_outlined),
                            label: Text(
                              busy ? 'Uploading…' : 'Upload classroom capture',
                            ),
                          ),
                          TextButton(
                            onPressed: busy || camera.busy
                                ? null
                                : camera.retake,
                            child: const Text('Retake recording'),
                          ),
                          TextButton(
                            onPressed: busy || camera.busy
                                ? null
                                : camera.discard,
                            child: const Text('Discard clip'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                if (captureError != null)
                  CaptureProblem(
                    failure: captureError!,
                    clipKept: camera.clip != null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (processingPending && capture == null)
          Panel(
            child: ProcessingProgress(
              info: ProcessingInfo.fromJson(data?['processing']),
              reference: widget.id.substring(0, 8),
            ),
          ),
        if (capture != null) ...[
          FutureBuilder<Json>(
            future: captureStatus(capture!['id'] as String),
            builder: (c, snapshot) {
              final quality = snapshot.hasData
                  ? captureQuality(snapshot.data!)
                  : null;
              final state = snapshot.data?['status'] as String?;
              return Panel(
                padding: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _CaptureStateIcon(
                          state: snapshot.hasError ? 'error' : state,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            snapshot.hasData
                                ? 'Capture: ${captureStatusLabel(state!)}'
                                : snapshot.hasError
                                ? 'Capture status unavailable. Refresh this session to retry.'
                                : 'Checking capture status…',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    if (quality != null) CaptureQualityNote(quality),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
        ],
        if ((editable || finalised) && rows.isEmpty)
          const MessageView(
            icon: Icons.groups_outlined,
            title: 'No students on this roster',
            message:
                'Approve subject membership in the Students tab before opening a new session.',
          )
        else if (finalised)
          PublishedAttendance(
            session: s,
            rows: rows,
            busy: busy,
            onCorrect: correct,
          )
        else if (editable)
          AttendanceReviewTable(
            rows: rows,
            decisions: decisions,
            editable: editable,
            finalised: false,
            busy: busy,
            onChanged: (id, status) => setState(() {
              decisions[id] = status;
              syncExitGuard();
            }),
            onApproveAllMatched: approveAllMatched,
            onCorrect: correct,
          ),
        if (editable && counts.toCheck > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Choose Present or Absent for ${counts.toCheck} more students.',
            ),
          ),
        if (!['scheduled', 'open', 'cancelled'].contains(status))
          _ReportsSection(
            published: finalised,
            reports: TeacherReports(
              api: services.api,
              institute: institute,
              sessionId: widget.id,
              supabaseUrl: services.config.supabaseUrl,
              sessionVersion: s['version'] as int,
            ),
          ),
      ],
    );
    if (!editable) return page;
    return Column(
      children: [
        Expanded(child: page),
        DecisionBar(
          counts: counts,
          busy: busy,
          canPublish:
              counts.toCheck == 0 && rows.isNotEmpty && !processingPending,
          showPublish: status != 'open',
          onSave: () => save(false),
          onPublish: () => save(true),
        ),
      ],
    );
  }
}

/// Counts marks and the remaining review work.
class DecisionCounts {
  DecisionCounts(this.present, this.absent, this.toCheck);
  factory DecisionCounts.of(List<Json> rows, Map<String, String> decisions) {
    var p = 0, a = 0, t = 0;
    for (final r in rows) {
      final v = decisions[r['student_id']] ?? r['status'] as String?;
      switch (finalStatus(v)) {
        case 'present':
          p++;
        case 'absent':
          a++;
        default:
          t++;
      }
    }
    return DecisionCounts(p, a, t);
  }
  final int present, absent, toCheck;
}

String publishedNote(int revision) {
  final corrections = revision - 1;
  return 'Published · students can see their attendance'
      '${corrections > 0 ? ' · corrected $corrections ${corrections == 1 ? 'time' : 'times'}' : ''}';
}

/// The one sentence for where the session is in its workflow.
String sessionStepHint(
  String status, {
  required bool captured,
}) => switch (status) {
  'scheduled' => 'Open the session at the start of class. This freezes the approved student list.',
  'open' when !captured =>
    'Scan the classroom, or go straight to review to mark attendance manually.',
  'open' => 'Add another scan if needed, then go to review. Uploads already accepted can finish processing there.',
  'closed' ||
  'review_required' ||
  'no_data' => 'Check the attendance marks and adjust them before publishing.',
  'finalized' =>
    'Attendance is published. Use Correct on a row to fix a mistake.',
  _ => 'This session was cancelled. Nothing was recorded.',
};

/// Open → Record → Close → Review → Publish, with the current step lit.
class SessionSteps extends StatelessWidget {
  const SessionSteps({super.key, required this.status, required this.captured});
  final String status;
  final bool captured;
  static const steps = [
    'Open session',
    'Record classroom',
    'Finish capture',
    'Review marks',
    'Publish',
  ];

  /// Index of the current step; [steps.length] when everything is done.
  static int current(String status, bool captured) => switch (status) {
    'scheduled' => 0,
    'open' => captured ? 2 : 1,
    'closed' || 'review_required' || 'no_data' => 3,
    'finalized' => steps.length,
    _ => -1,
  };

  @override
  Widget build(BuildContext context) {
    final at = current(status, captured);
    final scheme = Theme.of(context).colorScheme;
    final label = at < 0
        ? 'Cancelled'
        : at == steps.length
        ? 'Published'
        : 'Step ${at + 1} of ${steps.length} · ${steps[at]}';
    final tone = at < 0
        ? AppTone.neutral
        : at == steps.length
        ? AppTone.success
        : scheme.primary;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (at >= 0)
              LayoutBuilder(
                builder: (context, box) {
                  // Names under the dots only when each has room; the heading names the
                  // current step either way.
                  final named =
                      box.maxWidth / steps.length >= 92 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.3;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < steps.length; i++) ...[
                        if (i > 0)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 13),
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(99),
                                  color: i <= at ? scheme.primary : scheme.outlineVariant,
                                ),
                              ),
                            ),
                          ),
                        _StepDot(
                          index: i,
                          state: i < at
                              ? _DotState.done
                              : i == at
                              ? _DotState.current
                              : _DotState.todo,
                          label: named ? steps[i] : null,
                        ),
                      ],
                    ],
                  );
                },
              ),
            if (at >= 0) const SizedBox(height: AppSpace.md),
            Row(
              children: [
                if (at == steps.length) ...[
                  const Icon(Icons.verified_outlined, size: 20, color: AppTone.success),
                  const SizedBox(width: AppSpace.sm),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tone),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _DotState { done, current, todo }

class _StepDot extends StatelessWidget {
  const _StepDot({required this.index, required this.state, this.label});
  final int index;
  final _DotState state;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filled = state != _DotState.todo;
    final dot = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: state == _DotState.done ? scheme.primary : scheme.surface,
        border: Border.all(
          color: filled ? scheme.primary : scheme.outlineVariant,
          width: state == _DotState.current ? 3 : 2,
        ),
      ),
      alignment: Alignment.center,
      child: state == _DotState.done
          ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
          : Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: filled ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
    );
    if (label == null) return dot;
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          dot,
          const SizedBox(height: 4),
          Text(
            label!,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: state == _DotState.current ? FontWeight.w800 : FontWeight.w500,
              color: state == _DotState.todo ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureStateIcon extends StatelessWidget {
  const _CaptureStateIcon({required this.state});
  final String? state;
  @override
  Widget build(BuildContext context) => switch (state) {
    null => const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    'processing' => const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    'review_required' ||
    'completed' => const Icon(Icons.check_circle, color: Color(0xff176451)),
    'failed' ||
    'expired' ||
    'error' => const Icon(Icons.error_outline, color: Color(0xffa22f2f)),
    _ => const Icon(Icons.hourglass_top, color: Color(0xff9a6a00)),
  };
}

/// The session banner: subject, when and where, and the state.
class _SessionHero extends StatelessWidget {
  const _SessionHero({
    required this.session,
    required this.offering,
    required this.onRefresh,
  });
  final Json session;
  final Offering? offering;
  final VoidCallback? onRefresh;
  @override
  Widget build(BuildContext context) {
    final s = session, l = MaterialLocalizations.of(context);
    final start = DateTime.parse(s['starts_at'] as String).toLocal();
    final end = s['ends_at'] is String
        ? DateTime.parse(s['ends_at'] as String).toLocal()
        : null;
    final room = (s['room_label'] as String?) ?? '';
    final (color, icon) = SessionCard.style(s['status'] as String?);
    Widget chip(IconData i, String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x26ffffff),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(i, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff0d2a2c), Color(0xff135f50), Color(0xff23906f)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    offering?.title ?? 'Attendance session',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Refresh session',
                color: Colors.white,
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        sessionLabel(s['status'] as String? ?? ''),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              chip(Icons.event_outlined, l.formatMediumDate(start)),
              chip(
                Icons.schedule,
                '${l.formatTimeOfDay(TimeOfDay.fromDateTime(start))}'
                '${end == null ? '' : ' – ${l.formatTimeOfDay(TimeOfDay.fromDateTime(end))}'}',
              ),
              if (room.isNotEmpty) chip(Icons.meeting_room_outlined, room),
              if (offering != null)
                chip(Icons.groups_2_outlined, offering!.subtitle),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pinned at the bottom while reviewing: live counts and the two actions.
class DecisionBar extends StatelessWidget {
  const DecisionBar({
    super.key,
    required this.counts,
    required this.busy,
    required this.canPublish,
    required this.showPublish,
    required this.onSave,
    required this.onPublish,
  });
  final DecisionCounts counts;
  final bool busy, canPublish, showPublish;
  final VoidCallback onSave, onPublish;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget count(String label, int n, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '$label $n',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 10,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        count(
                          'Present',
                          counts.present,
                          const Color(0xff176451),
                        ),
                        count('Absent', counts.absent, const Color(0xffa22f2f)),
                        if (counts.toCheck > 0)
                          count('To check', counts.toCheck, scheme.primary),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy ? null : onSave,
                        child: const Text('Save draft decisions'),
                      ),
                      if (showPublish)
                        FilledButton.icon(
                          onPressed: busy || !canPublish ? null : onPublish,
                          icon: const Icon(Icons.send_outlined),
                          label: const Text('Publish attendance'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _captureIsPending(Object? status) =>
    const {'awaiting_upload', 'queued', 'processing'}.contains(status);

/// Short checklist shown before recording a classroom clip.
class RecordingTips extends StatelessWidget {
  const RecordingTips({super.key});
  static const tips = [
    (Icons.light_mode_outlined, 'Make sure light falls on students’ faces.'),
    (
      Icons.social_distance_outlined,
      'Move closer if faces look small or blurry.',
    ),
    (
      Icons.timer_outlined,
      'Pause on each group for a few seconds before moving to the next.',
    ),
    (
      Icons.video_library_outlined,
      'The scan saves short clips automatically with audio off.',
    ),
    (
      Icons.cloud_upload_outlined,
      'Keep this page open until the upload finishes.',
    ),
  ];
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (icon, text) in tips)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(text)),
              ],
            ),
          ),
      ],
    ),
  );
}

/// After at least one processed clip: how many students who can be recognised
/// (they have an approved face enrolment) were found so far.
CaptureQuality? captureCoverage(List<Json> rows) {
  final assessed = rows.where((r) => r['assessment_code'] != null).toList();
  if (assessed.isEmpty) return null;
  final eligible = assessed
      .where((r) => r['assessment_code'] != 'template_ineligible')
      .toList();
  final noFace = assessed.length - eligible.length;
  final found = eligible
      .where((r) => r['assessment_code'] == 'recognized')
      .length;
  final missing = eligible.length - found;
  final parts = <String>[
    if (eligible.isEmpty)
      'No student on this roster has an approved face enrolment yet, so nobody can be recognised.'
    else
      'Recognised so far: $found of ${eligible.length} students with face enrolment.',
    if (eligible.isNotEmpty && missing > 0)
      '$missing not seen yet: record another clip covering them.',
    if (noFace > 0)
      '$noFace without face enrolment. Check their marks manually.',
  ];
  return CaptureQuality(parts.join(' '), poor: eligible.isEmpty || missing > 0);
}

/// What processing said about a capture's frames, from `quality_json.counts`.
class CaptureQuality {
  const CaptureQuality(this.text, {required this.poor});
  final String text;
  final bool poor;
}

const _retakeTips =
    'Record again closer (0.5–1 m from each face), with light on faces and no window behind them, holding each face steady for 3–4 seconds.';

/// Show guidance only when the sampled frames indicate a capture problem.
CaptureQuality? captureQuality(Json capture) {
  final quality = capture['quality_json'];
  final counts = quality is Map ? quality['counts'] : null;
  if (counts is! Map) return null;
  final sampled = (counts['sampled_frames'] as num?)?.toInt() ?? 0;
  final faces = (counts['detections'] as num?)?.toInt() ?? 0;
  final rejected = (counts['quality_rejects'] as num?)?.toInt() ?? 0;
  if (sampled == 0) return null;
  final usable = (faces - rejected).clamp(0, faces);
  if (faces == 0) {
    return CaptureQuality(
      'No faces were detected in the frames checked. Point the camera at students\' faces. $_retakeTips',
      poor: true,
    );
  }
  if (usable * 2 < faces) {
    final cause = rejectCause(quality);
    return CaptureQuality(
      'The camera did not get a clear view of enough faces. ${cause == null ? '' : '$cause '}Check the attendance marks and record another clip if needed. $_retakeTips',
      poor: true,
    );
  }
  return null;
}

class CaptureQualityNote extends StatelessWidget {
  const CaptureQualityNote(this.quality, {super.key});
  final CaptureQuality quality;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: quality.poor ? const Color(0xfffff1db) : const Color(0xffe3f4ea),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          quality.poor
              ? Icons.tips_and_updates_outlined
              : Icons.check_circle_outline,
          color: quality.poor
              ? const Color(0xffa15c07)
              : const Color(0xff1d7a4f),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(quality.text)),
      ],
    ),
  );
}

class CaptureProblem extends StatelessWidget {
  const CaptureProblem({
    super.key,
    required this.failure,
    required this.clipKept,
  });
  final AppFailure failure;
  final bool clipKept;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'The recording was not uploaded',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(failure.message),
                  const SizedBox(height: 4),
                  Text(
                    clipKept
                        ? 'Your recording is kept. Check the connection and tap Upload again; it resumes safely.'
                        : 'Record the classroom again to retry.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String captureStatusLabel(String status) => switch (status) {
  'awaiting_upload' => 'waiting for upload',
  'queued' => 'waiting for processing',
  'processing' => 'processing video',
  'review_required' => 'ready for attendance review',
  'failed' => 'processing failed — review manually',
  'expired' => 'upload expired',
  _ => status.replaceAll('_', ' '),
};

class _ScanUpload {
  _ScanUpload({DateTime? at}) : recordedAt = at ?? DateTime.now().toUtc();
  final DateTime recordedAt;
  final reserve = Mutation(), complete = Mutation();
  Json? capture;
  String? resumeUrl;
  bool uploaded = false;
  Json toJson() => {
    'recorded_at': recordedAt.toIso8601String(),
    'reserve_key': reserve.key,
    'complete_key': complete.key,
    'capture': capture,
    'resume_url': resumeUrl,
    'uploaded': uploaded,
  };
  factory _ScanUpload.fromJson(Json data) {
    final state = _ScanUpload(at: DateTime.parse(data['recorded_at'] as String));
    state.reserve.key = data['reserve_key'] as String;
    state.complete.key = data['complete_key'] as String;
    state.capture = (data['capture'] as Map?)?.cast<String, dynamic>();
    state.resumeUrl = data['resume_url'] as String?;
    state.uploaded = data['uploaded'] == true;
    return state;
  }
}

// -----------------------------------------------------------------------------
// Published attendance
// -----------------------------------------------------------------------------

/// How a published mark came about, from what the attendance rows carry.
///
/// `source` is not used: every decision the teacher submits, including a confirmed camera
/// suggestion, is stored as `teacher`. The assessment code says what the camera found.
enum MarkOrigin { recognised, overridden, byHand, byHandNoEnrolment }

MarkOrigin markOrigin(Json row) {
  if (row['assessment_code'] == 'recognized') {
    return finalStatus(row['status'] as String?) == 'present'
        ? MarkOrigin.recognised
        : MarkOrigin.overridden;
  }
  if (row['assessment_code'] == 'template_ineligible' ||
      row['recognition_eligible'] == false) {
    return MarkOrigin.byHandNoEnrolment;
  }
  return MarkOrigin.byHand;
}

extension MarkOriginText on MarkOrigin {
  String get label => switch (this) {
    MarkOrigin.recognised => 'Recognised by camera · confirmed by you',
    MarkOrigin.overridden => 'Recognised by camera · you marked Absent',
    MarkOrigin.byHand => 'Marked by hand',
    MarkOrigin.byHandNoEnrolment => 'Marked by hand · no face enrolment',
  };
  IconData get icon => switch (this) {
    MarkOrigin.recognised => Icons.center_focus_strong_outlined,
    MarkOrigin.overridden => Icons.swap_horiz,
    MarkOrigin.byHand => Icons.edit_outlined,
    MarkOrigin.byHandNoEnrolment => Icons.person_off_outlined,
  };
}

/// The reason typed with a correction. Ordinary review decisions carry none.
String? correctionReason(Json row) {
  final reason = (row['reason'] as String?)?.trim();
  return reason == null || reason.isEmpty ? null : reason;
}

/// Totals for the published header, counted from the rows with the same folding of legacy
/// statuses as the review bar.
class PublishedSummary {
  const PublishedSummary({
    required this.total,
    required this.present,
    required this.absent,
    required this.recognised,
    required this.corrected,
    required this.scanned,
  });
  factory PublishedSummary.of(List<Json> rows) {
    var present = 0, absent = 0, recognised = 0, corrected = 0;
    var scanned = false;
    for (final row in rows) {
      switch (finalStatus(row['status'] as String?)) {
        case 'present':
          present++;
        case 'absent':
          absent++;
      }
      if (markOrigin(row) == MarkOrigin.recognised) recognised++;
      if (correctionReason(row) != null) corrected++;
      if (row['assessment_code'] != null) scanned = true;
    }
    return PublishedSummary(
      total: rows.length,
      present: present,
      absent: absent,
      recognised: recognised,
      corrected: corrected,
      scanned: scanned,
    );
  }
  final int total, present, absent, recognised, corrected;

  /// Whether a camera scan was assessed for this session at all.
  final bool scanned;
  int get notAssessed => total - present - absent;
  int get byHand => total - recognised;

  /// Present out of everyone assessed Present or Absent; null when nobody was.
  double? get percent {
    final assessed = present + absent;
    return assessed == 0 ? null : present * 100 / assessed;
  }
}

enum PublishedFilter { all, present, absent, corrected }

/// The published session: a success header with the totals, the roster grouped by mark with
/// search and filters, and the corrections made since publishing.
class PublishedAttendance extends StatefulWidget {
  const PublishedAttendance({
    super.key,
    required this.session,
    required this.rows,
    required this.busy,
    required this.onCorrect,
  });
  final Json session;
  final List<Json> rows;
  final bool busy;
  final void Function(Json row) onCorrect;
  @override
  State<PublishedAttendance> createState() => _PublishedAttendanceState();
}

class _PublishedAttendanceState extends State<PublishedAttendance> {
  String _search = '';
  PublishedFilter _filter = PublishedFilter.all;

  static int _byName(Json a, Json b) =>
      '${a['official_name']}'.toLowerCase().compareTo('${b['official_name']}'.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final summary = PublishedSummary.of(widget.rows);
    final revision = widget.session['attendance_revision'] as int? ?? 1;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = narrow ? 16.0 : 24.0;
    final query = _search.trim().toLowerCase();
    final sorted = [...widget.rows]..sort(_byName);
    List<Json> shown(String status) => [
      for (final row in sorted)
        if (finalStatus(row['status'] as String?) == status &&
            (query.isEmpty ||
                '${row['official_name']} ${row['enrollment_number']}'
                    .toLowerCase()
                    .contains(query)) &&
            (_filter != PublishedFilter.corrected || correctionReason(row) != null))
          row,
    ];
    final groups = [
      if (_filter != PublishedFilter.absent)
        ('Present', 'present', AppTone.success, Icons.check_circle_outline, shown('present')),
      if (_filter != PublishedFilter.present)
        ('Absent', 'absent', AppTone.danger, Icons.cancel_outlined, shown('absent')),
      if (summary.notAssessed > 0 && _filter != PublishedFilter.present && _filter != PublishedFilter.absent)
        ('Not assessed', 'unassessed', AppTone.neutral, Icons.help_outline, shown('unassessed')),
    ];
    final anyShown = groups.any((g) => g.$5.isNotEmpty);
    final corrections = [for (final row in sorted) if (correctionReason(row) != null) row];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PublishedHeader(summary: summary, revision: revision, padding: pad),
        const SizedBox(height: AppSpace.lg),
        Panel(
          padding: pad,
          child: Column(
            key: const ValueKey('published-list'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text('Attendance list', style: Theme.of(context).textTheme.titleLarge),
              ),
              const SizedBox(height: 2),
              Text(
                'Tap Correct on a student to publish a fix. Students see the new mark.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('published-search'),
                onChanged: (text) => setState(() => _search = text),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search name or enrolment',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final (filter, label) in [
                    (PublishedFilter.all, 'All · ${summary.total}'),
                    (PublishedFilter.present, 'Present · ${summary.present}'),
                    (PublishedFilter.absent, 'Absent · ${summary.absent}'),
                    if (summary.corrected > 0)
                      (PublishedFilter.corrected, 'Corrected · ${summary.corrected}'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
                ],
              ),
              if (!anyShown)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpace.lg),
                  child: EmptyState(
                    compact: true,
                    icon: Icons.search_off,
                    title: 'No students match.',
                    message: 'Clear the search or choose All.',
                  ),
                ),
              for (final (label, _, tone, icon, rows) in groups)
                if (rows.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.lg),
                  _GroupHeader(label: label, count: rows.length, tone: tone, icon: icon),
                  for (final row in rows) ...[
                    const Divider(height: 1),
                    _PublishedRow(
                      key: ValueKey('published-row-${row['student_id']}'),
                      row: row,
                      busy: widget.busy,
                      onCorrect: widget.onCorrect,
                    ),
                  ],
                ],
            ],
          ),
        ),
        if (corrections.isNotEmpty) ...[
          const SizedBox(height: AppSpace.lg),
          Panel(
            padding: pad,
            child: Column(
              key: const ValueKey('published-corrections'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note, color: AppTone.warning),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Correction notes · ${corrections.length}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'The latest correction note for each corrected student. A student corrected more than once shows only the newest note; earlier versions stay on record.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpace.sm),
                for (final row in corrections) ...[
                  const Divider(height: 1),
                  _CorrectionEntry(row: row),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _PublishedHeader extends StatelessWidget {
  const _PublishedHeader({required this.summary, required this.revision, required this.padding});
  final PublishedSummary summary;
  final int revision;
  final double padding;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final times = revision - 1;
    final banner = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppTone.tint(AppTone.success, .12),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: const Icon(Icons.verified_outlined, color: AppTone.success),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: const Text(
                  'Attendance published',
                  key: ValueKey('published-title'),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTone.success),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Students can see their attendance.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              if (times > 0) ...[
                const SizedBox(height: AppSpace.sm),
                TonePill(
                  'Corrected $times ${times == 1 ? 'time' : 'times'}',
                  tone: AppTone.warning,
                  icon: Icons.edit_note,
                ),
              ],
            ],
          ),
        ),
      ],
    );
    final stats = StatGrid(
      minTileWidth: 100,
      children: [
        StatTile(label: 'Present', value: summary.present, icon: Icons.check_circle_outline, accent: AppTone.success),
        StatTile(label: 'Absent', value: summary.absent, icon: Icons.cancel_outlined, accent: AppTone.danger),
        StatTile(label: 'Students', value: summary.total, icon: Icons.groups_2_outlined, accent: AppTone.neutral),
        if (summary.notAssessed > 0)
          StatTile(label: 'Not assessed', value: summary.notAssessed, icon: Icons.help_outline, accent: AppTone.neutral),
        if (summary.scanned)
          StatTile(label: 'By camera', value: summary.recognised, icon: Icons.center_focus_strong_outlined, accent: AppTone.info),
        if (summary.scanned)
          StatTile(label: 'By hand', value: summary.byHand, icon: Icons.edit_outlined, accent: AppTone.neutral),
      ],
    );
    final ring = Center(
      child: PercentRing(value: summary.percent, size: 112, caption: 'present'),
    );
    return Panel(
      accent: true,
      padding: padding,
      child: Column(
        key: const ValueKey('published-summary'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(label: publishedNote(revision), child: banner),
          const SizedBox(height: AppSpace.lg),
          LayoutBuilder(
            builder: (context, box) => box.maxWidth >= 560
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [ring, const SizedBox(width: AppSpace.xl), Expanded(child: stats)],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [ring, const SizedBox(height: AppSpace.lg), stats],
                  ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count, required this.tone, required this.icon});
  final String label;
  final int count;
  final Color tone;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Semantics(
      header: true,
      label: '$label, $count',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(icon, size: 20, color: tone),
            const SizedBox(width: AppSpace.sm),
            Flexible(
              child: Text(
                label,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: tone),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            TonePill('$count', tone: tone),
          ],
        ),
      ),
    ),
  );
}

class _PublishedRow extends StatelessWidget {
  const _PublishedRow({super.key, required this.row, required this.busy, required this.onCorrect});
  final Json row;
  final bool busy;
  final void Function(Json row) onCorrect;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = finalStatus(row['status'] as String?);
    final tone = status == 'present'
        ? AppTone.success
        : status == 'absent'
        ? AppTone.danger
        : AppTone.neutral;
    final name = row['official_name'] as String? ?? 'Student';
    final origin = markOrigin(row);
    final number = row['enrollment_number'] as String?;
    final avatar = CircleAvatar(
      radius: 20,
      backgroundColor: AppTone.tint(tone, .12),
      child: Text(
        initialsOf(name),
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: tone),
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        if (number != null)
          Text(number, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: AppSpace.xs),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(origin.icon, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    origin.label,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (correctionReason(row) != null)
              const TonePill('Corrected', tone: AppTone.warning, icon: Icons.edit_note),
          ],
        ),
      ],
    );
    final correct = TextButton.icon(
      onPressed: busy ? null : () => onCorrect(row),
      style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
      icon: const Icon(Icons.edit_outlined, size: 18),
      label: const Text('Correct'),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      child: LayoutBuilder(
        builder: (context, box) {
          final stacked = box.maxWidth < 440 || MediaQuery.textScalerOf(context).scale(1) > 1.3;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              avatar,
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [details, Align(alignment: Alignment.centerLeft, child: correct)],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [Expanded(child: details), const SizedBox(width: AppSpace.sm), correct],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CorrectionEntry extends StatelessWidget {
  const _CorrectionEntry({required this.row});
  final Json row;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mark = finalStatus(row['status'] as String?);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                row['official_name'] as String? ?? 'Student',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (finalStatuses.contains(mark)) StatusBadge(mark),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Reason: ${correctionReason(row)}',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// The reports area: what can be downloaded now, kept apart from the attendance and
/// corrections above it.
class _ReportsSection extends StatelessWidget {
  const _ReportsSection({required this.published, required this.reports});
  final bool published;
  final Widget reports;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('reports-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpace.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(Icons.description_outlined, color: scheme.primary),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text('Reports', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    published
                        ? 'Download the final attendance report as PDF or CSV. A corrected publication creates a new report version.'
                        : 'Download the attendance report as PDF or CSV. The final report is ready once attendance is published.',
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        reports,
      ],
    );
  }
}

/// Raises the minimum height of the page's buttons to a comfortable touch target.
ThemeData _tallButtons(ThemeData t, {double height = 48}) {
  final min = WidgetStatePropertyAll(Size(64, height));
  ButtonStyle tall(ButtonStyle? base) =>
      (base ?? const ButtonStyle()).copyWith(minimumSize: min);
  return t.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: tall(t.filledButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: tall(t.outlinedButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: tall(t.textButtonTheme.style)),
  );
}

/// The buttons for the current step: side by side when there is room, else one per row.
class _StepActions extends StatelessWidget {
  const _StepActions({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Theme(
    data: _tallButtons(Theme.of(context)),
    child: LayoutBuilder(
      builder: (context, box) => box.maxWidth < 480
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final child in children)
                  Padding(padding: const EdgeInsets.only(bottom: AppSpace.sm), child: child),
              ],
            )
          : Wrap(spacing: AppSpace.md, runSpacing: AppSpace.sm, children: children),
    ),
  );
}

/// An icon tile, a title and an optional one-line explanation.
class _PanelHeading extends StatelessWidget {
  const _PanelHeading({required this.icon, required this.title, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, color: scheme.primary),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(title, style: Theme.of(context).textTheme.titleLarge),
              ),
              if (subtitle != null)
                Text(subtitle!, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Numbered instructions.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.steps});
  final List<String> steps;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, text) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .10),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: scheme.primary),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
              ],
            ),
          ),
      ],
    );
  }
}

/// A tinted note with an icon: a warning or a hint inside a panel.
class _Callout extends StatelessWidget {
  const _Callout({required this.icon, required this.tone, required this.text});
  final IconData icon;
  final Color tone;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.md),
    decoration: BoxDecoration(
      color: AppTone.tint(tone, .09),
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppTone.tint(tone, .3)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: tone),
        const SizedBox(width: AppSpace.md),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ],
    ),
  );
}
