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
    this.version = 0,
    this.changed,
  });
  final ApiClient api;
  final String institute, offering, publishableKey;

  /// A change reloads the list (the subject page's refresh).
  final int version;

  /// Called after sessions were created or imported.
  final VoidCallback? changed;
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

  Future<void> load() async {
    final generation = ++_generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rows = await fetchAllPages(
        widget.api,
        '/v1/sessions',
        widget.institute,
        query: {'offering_id': widget.offering},
        maxPages: 10,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        sessions = rows;
        loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
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
    await load();
    widget.changed?.call();
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
        title: 'No sessions yet',
        message: 'Create a session for your next class or import a timetable.',
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
                child: SessionCard(session: s),
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
            IconButton(
              tooltip: 'Refresh sessions',
              onPressed: loading ? null : load,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (all.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text('All ${all.length}'),
                selected: filter == null,
                onSelected: (_) => setState(() => filter = null),
              ),
              for (final g in SessionGroup.values)
                if (groups[g]!.isNotEmpty)
                  ChoiceChip(
                    label: Text(
                      '${switch (g) {
                        SessionGroup.todo => 'To do',
                        SessionGroup.upcoming => 'Upcoming',
                        SessionGroup.published => 'Published',
                        SessionGroup.cancelled => 'Cancelled',
                      }} ${groups[g]!.length}',
                    ),
                    selected: filter == g,
                    onSelected: (_) => setState(() => filter = g),
                  ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        list,
      ],
    );
  }
}

/// One session: a calendar tile, time and room, its state and the next step.
class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.session});
  final Json session;

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
    void open() => context.push('/sessions/${s['id']}');
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
  int webPreviewTurns = 0;
  final decisions = <String, String>{};
  final camera = GuidedCamera(
    analyzerFactory: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
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
      onPause: () {
        if (!scanActive) unawaited(camera.interrupt());
      },
      onResume: load,
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

  void _schedulePoll({bool failed = false}) {
    poll?.cancel();
    if (!mounted) return;
    if (data?['session']?['status'] == 'open' || processingPending) {
      poll = Timer(
        Duration(seconds: failed ? 15 : 5),
        () => load(keepDecisions: processingPending),
      );
    }
  }

  /// [keepDecisions] re-applies unsaved choices over the fresh rows (after an
  /// upload or close); a saved draft or [discardChanges] starts clean.
  Future<void> load({
    bool discardChanges = false,
    bool keepDecisions = false,
  }) async {
    if (decisions.isNotEmpty && !busy && !discardChanges && !keepDecisions) {
      _schedulePoll();
      return;
    }
    final kept = keepDecisions ? Map.of(decisions) : const <String, String>{};
    final current = ++loadGeneration;
    try {
      final result = await services.api.send(
        'GET',
        '/v1/sessions/${widget.id}/attendance',
        institute: institute,
      );
      if (!mounted || current != loadGeneration) return;
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
        setState(
          () => error = e is AppFailure
              ? e
              : const AppFailure('Could not load this session. Retry.'),
        );
        _schedulePoll(failed: true);
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
    reason.dispose();
    await load();
    if (mounted && data?['session']['status'] == 'cancelled') {
      await camera.interrupt();
    }
  }

  Future<List<String>> scanSuggestions() async {
    final result = await services.api.send(
      'GET',
      '/v1/sessions/${widget.id}/attendance',
      institute: institute,
    );
    return [
      for (final row in (result['items'] as List).cast<Json>())
        if (row['status'] == 'proposed_present')
          row['official_name'] as String? ?? 'Enrolled student',
    ];
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
        'Captured segment is empty or exceeds 25 MiB. Record again at a lower resolution.',
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
          },
        );
        state.uploaded = true;
      }
      await commit();
    }
    if (!mounted) return;
    capture = {...current, 'status': 'queued'};
    captureStatusId = null;
    captureStatusRequest = null;
    scanUploads.remove(file.path);
  }

  Future<void> openClassroomScan() async {
    if (scanActive || busy || camera.recording || camera.clip != null) return;
    setState(() => scanActive = true);
    ClassroomScan? scan;
    try {
      await camera.interrupt();
      if (!mounted) return;
      if (kIsWeb) {
        await scanClassroomInBrowser(
          onSegment: (file) async {
            try {
              await uploadScanSegment(
                file,
                report: (message, [value]) => updateBrowserClassroomStatus(
                  value == null
                      ? message
                      : '$message ${(value * 100).round()}%',
                ),
              );
              return null;
            } catch (error) {
              final message = terminalClassroomUploadMessage(error);
              if (message == null) rethrow;
              return message;
            }
          },
          onStarted: () {},
        );
      } else {
        scan = ClassroomScan(
          camera,
          (file) => uploadScanSegment(file, report: scan!.reportUpload),
        );
        if (!mounted) return;
        await Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) =>
                ClassroomScanPage(scan: scan!, suggestions: scanSuggestions),
          ),
        );
      }
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
          children: [
            Text(row['official_name']),
            DropdownButtonFormField<String>(
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
    if (scanActive && kIsWeb) cancelBrowserClassroomScan();
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
    final editable = ![
      'open',
      'scheduled',
      'cancelled',
      'finalized',
    ].contains(s['status']);
    final status = s['status'] as String;
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                sessionStepHint(status, captured: captured),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (['scheduled', 'open'].contains(status)) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Classroom capture',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scan the room, then tap Stop scan. The camera closes while uploads finish.',
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed:
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
                ExpansionTile(
                  title: const Text('Recording tips'),
                  children: const [RecordingTips()],
                ),
                if (captureCoverage(rows) case final coverage?)
                  CaptureQualityNote(coverage),
                ExpansionTile(
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
                      if (camera.recording && !kIsWeb)
                        ListenableBuilder(
                          listenable: camera.faceTracker,
                          builder: (context, _) => Text(
                            camera.faceTracker.available
                                ? camera.faceTracker.faces.isEmpty
                                      ? 'No faces in view. Aim the camera toward the class.'
                                      : 'Green outlines show faces that are well framed.'
                                : 'Live face guidance is currently unavailable. Recording continues.',
                          ),
                        ),
                    ],
                    if (camera.error != null) Text(camera.error!),
                    if (camera.recording)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.fiber_manual_record,
                              color: Color(0xffc62828),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text('Recording ${camera.elapsed} / 15 seconds'),
                          ],
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
          const Panel(
            child: Text('Recording is processing. Results will update here.'),
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
          const Panel(
            child: Text(
              'No students on this roster. Approve subject membership before opening a new session.',
            ),
          )
        else if (editable || finalised)
          AttendanceReviewTable(
            rows: rows,
            decisions: decisions,
            editable: editable,
            finalised: finalised,
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
        if (finalised) ...[
          const SizedBox(height: 16),
          Panel(
            child: Row(
              children: [
                const Icon(Icons.verified_outlined, color: Color(0xff176451)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    publishedNote(s['attendance_revision'] as int? ?? 1),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (!['scheduled', 'open', 'cancelled'].contains(status)) ...[
          const SectionTitle('Reports'),
          Text(
            'A draft report follows a closed session; the final report uses the published attendance. Download it as CSV or PDF.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TeacherReports(
            api: services.api,
            institute: institute,
            sessionId: widget.id,
            supabaseUrl: services.config.supabaseUrl,
            sessionVersion: s['version'] as int,
          ),
        ],
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
    final label = at < 0
        ? 'Cancelled'
        : at == steps.length
        ? 'Published'
        : 'Step ${at + 1} of ${steps.length} · ${steps[at]}';
    return Text(label, style: Theme.of(context).textTheme.titleMedium);
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
    (Icons.light_mode_outlined, 'Light on faces, no window behind students.'),
    (Icons.social_distance_outlined, 'Stay 0.5–1 m from each face.'),
    (
      Icons.timer_outlined,
      'Hold each face steady for 3–4 seconds, then move slowly.',
    ),
    (
      Icons.video_library_outlined,
      'Each clip is 15 s with audio off. For a bigger class, record 2–3 clips: each adds recognised students.',
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

/// Null until processing has produced frame counts.
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
      'No faces were found in the $sampled frames checked. Point the camera at students\' faces. $_retakeTips',
      poor: true,
    );
  }
  if (usable * 2 < faces) {
    return CaptureQuality(
      'Only $usable of $faces detected faces were clear enough. Review the remaining students manually. $_retakeTips',
      poor: true,
    );
  }
  return CaptureQuality(
    '$usable of $faces faces found were clear enough to use.',
    poor: false,
  );
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
  final recordedAt = DateTime.now().toUtc();
  final reserve = Mutation(), complete = Mutation();
  Json? capture;
  String? resumeUrl;
  bool uploaded = false;
}
