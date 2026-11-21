import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'student_attendance.dart';
import 'student_ui.dart';

/// The Student landing page: a greeting, the next step for face registration,
/// an attendance snapshot, anything that needs attention, and the subject list.
class StudentClasses extends ConsumerStatefulWidget {
  const StudentClasses({super.key});
  @override
  ConsumerState<StudentClasses> createState() => _StudentClassesState();
}

class _StudentClassesState extends ConsumerState<StudentClasses>
    with ResumeRefresh<StudentClasses> {
  late final ApiClient api;
  late final String institute;
  late final PagedController<Enrollment> controller;
  BiometricState? face;
  List<Json>? records;
  bool snapshotLoading = true, faceFailed = false, recordsFailed = false;
  int _snapshotGeneration = 0;

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    controller = PagedController(
      (cursor) => api.enrollments(institute, cursor: cursor),
    );
    controller.load();
    loadSnapshot();
    watchLifecycle();
  }

  @override
  void refreshOnResume() {
    controller.load();
    loadSnapshot();
  }

  @override
  void dispose() {
    unwatchLifecycle();
    controller.dispose();
    super.dispose();
  }

  Future<void> refreshAll() async {
    await Future.wait([controller.load(), loadSnapshot()]);
  }

  /// Loads face-registration state and published attendance. Each part fails
  /// on its own so a problem in one never hides the other or the subject list.
  Future<void> loadSnapshot() async {
    final generation = ++_snapshotGeneration;
    if (mounted && face == null && records == null) {
      setState(() => snapshotLoading = true);
    }
    final results = await Future.wait([
      () async {
        try {
          return BiometricState.fromJson(
            await api.send(
              'GET',
              '/v1/me/biometric-enrollment',
              institute: institute,
            ),
          );
        } catch (_) {
          return null;
        }
      }(),
      () async {
        try {
          return await fetchAllPages(api, '/v1/me/attendance', institute);
        } catch (_) {
          return null;
        }
      }(),
    ]);
    if (!mounted || generation != _snapshotGeneration) return;
    setState(() {
      face = results[0] as BiometricState? ?? face;
      faceFailed = results[0] == null && face == null;
      records = results[1] as List<Json>? ?? records;
      recordsFailed = results[1] == null && records == null;
      snapshotLoading = false;
    });
  }

  Future<void> join() async {
    final code = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Join a subject',
        button: 'Send request',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ask your faculty for the subject join code. They will approve your request before attendance is recorded.',
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: code,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Join code',
                hintText: 'XXXX-XXXX-XXXX',
              ),
              validator: requiredText,
            ),
          ],
        ),
        submit: (mutation) async {
          await api.send(
            'POST',
            '/v1/enrollment-requests',
            institute: institute,
            body: {'join_code': code.text.trim()},
            mutation: mutation,
          );
        },
      ),
    );
    code.dispose();
    if (mounted && submitted == true) await controller.load();
  }

  String? get _firstName {
    final auth = ref.read(authProvider);
    final people = auth.account?.students ?? const <Person>[];
    final mine = people.where((p) => p.instituteId == auth.institute);
    return firstName((mine.isEmpty ? people : mine).firstOrNull?.name);
  }

  Map<String, AttendanceStats> get _bySubject {
    final groups = <String, List<Json>>{};
    for (final r in records ?? const <Json>[]) {
      groups.putIfAbsent(r['offering_id'] as String, () => []).add(r);
    }
    return {for (final e in groups.entries) e.key: AttendanceStats(e.value)};
  }

  @override
  Widget build(BuildContext context) {
    final name = _firstName;
    final stats = _bySubject;
    return ContentPage(
      onRefresh: refreshAll,
      children: [
        PageHeader(
          title: name == null ? greeting() : '${greeting()}, $name',
          subtitle: 'Your attendance and face registration at a glance.',
          action: IconButton(
            tooltip: 'Refresh',
            onPressed: refreshAll,
            icon: const Icon(Icons.refresh),
          ),
        ),
        _FaceCard(
          state: face,
          loading: snapshotLoading,
          failed: faceFailed,
          retry: loadSnapshot,
        ),
        const SizedBox(height: 16),
        _AttendanceCard(
          records: records,
          loading: snapshotLoading,
          failed: recordsFailed,
          retry: loadSnapshot,
        ),
        const _Alerts(),
        SectionTitle(
          'Your subjects',
          trailing: FilledButton.tonalIcon(
            onPressed: join,
            icon: const Icon(Icons.add),
            label: const Text('Join subject'),
          ),
        ),
        PagedList(
          controller: controller,
          emptyTitle: 'No subjects yet',
          emptyMessage:
              'Ask your faculty for a join code, then tap Join subject to request access.',
          item: (Enrollment e) => SubjectTile(
            title: e.offering!.title,
            subtitle: e.offering!.subtitle,
            status: e.status == 'active' ? null : e.status,
            note: switch (e.status) {
              'requested' => 'Waiting for faculty approval.',
              'rejected' =>
                e.reason != null && e.reason!.isNotEmpty
                    ? 'Declined: ${e.reason}'
                    : 'Declined. Contact your faculty to rejoin.',
              'withdrawn' =>
                'Membership ended. Contact your faculty to rejoin.',
              _ => null,
            },
            extra: e.status == 'active' && stats[e.offeringId] != null
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: PercentPill(
                      stats[e.offeringId]!.percentage,
                      color: percentColor(stats[e.offeringId]!.percentage),
                    ),
                  )
                : null,
            onTap: e.status == 'active'
                ? () => context.push('/classes/${e.offeringId}')
                : null,
          ),
        ),
      ],
    );
  }
}

/// The primary card: face registration progress, or a slim confirmation once
/// the face enrolment is active.
class _FaceCard extends StatelessWidget {
  const _FaceCard({
    required this.state,
    required this.loading,
    required this.failed,
    required this.retry,
  });
  final BiometricState? state;
  final bool loading, failed;
  final VoidCallback retry;

  static String headline(BiometricState s) {
    if (s.consentId == null) return 'Register your face';
    return switch (s.attempt?.status) {
      'awaiting_upload' => 'Finish your registration',
      'queued' || 'processing' => 'We are checking your video',
      'review_required' => 'Waiting for faculty review',
      'failed' ||
      'rejected' ||
      'expired' ||
      'cancelled' => 'Please record your video again',
      _ => 'Register your face',
    };
  }

  static String action(RegistrationProgress p, BiometricState s) {
    if (p.step == 0) return 'Start registration';
    if (p.step == 1) {
      return s.attempt?.status == 'awaiting_upload'
          ? 'Continue registration'
          : s.attempt == null
          ? 'Record your video'
          : 'Record again';
    }
    if (p.step == 2) return 'Upload your video';
    return 'View progress';
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s == null) {
      if (loading) return const SkeletonCard();
      return InlineNotice(
        failed
            ? 'We could not check your face registration.'
            : 'Face registration is unavailable right now.',
        icon: Icons.face_outlined,
        onRetry: retry,
      );
    }
    final progress = RegistrationProgress.of(s);
    final theme = Theme.of(context);
    if (progress.complete) {
      return Panel(
        padding: 16,
        child: Row(
          children: [
            const IconTile(Icons.verified_outlined, color: studentGreen),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Face registration complete',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    'You are ready for classroom recognition.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => context.go('/enrolment'),
              child: const Text('Details'),
            ),
          ],
        ),
      );
    }
    return Panel(
      accent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(headline(s), style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            progress.next,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          StepProgress(progress),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => context.go('/enrolment'),
              icon: Icon(
                progress.step == 3
                    ? Icons.hourglass_top_outlined
                    : Icons.face_retouching_natural_outlined,
              ),
              label: Text(action(progress, s)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Overall attendance at a glance, with the next-step advice.
class _AttendanceCard extends StatelessWidget {
  const _AttendanceCard({
    required this.records,
    required this.loading,
    required this.failed,
    required this.retry,
  });
  final List<Json>? records;
  final bool loading, failed;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    final rows = records;
    if (rows == null) {
      if (loading) return const SkeletonCard();
      return failed
          ? InlineNotice(
              'We could not load your attendance.',
              icon: Icons.insights_outlined,
              onRetry: retry,
            )
          : const SizedBox.shrink();
    }
    final stats = AttendanceStats(rows);
    final theme = Theme.of(context);
    if (stats.assessed == 0) {
      return Panel(
        padding: 16,
        child: Row(
          children: [
            const IconTile(Icons.insights_outlined),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your attendance', style: theme.textTheme.titleMedium),
                  Text(
                    'Nothing published yet. It appears here once your faculty reviews a class.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PercentRing(
                value: stats.percentage,
                size: 104,
                caption: 'overall',
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420, minWidth: 180),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your attendance',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${stats.present} present · ${stats.absent} absent',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(attendanceAdvice(stats)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.go('/attendance'),
              child: const Text('View full attendance'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Items that need the student, from the notification centre. Face
/// registration is excluded because the card above already owns that step.
class _Alerts extends StatelessWidget {
  const _Alerts();
  @override
  Widget build(BuildContext context) {
    final center = NotificationScope.of(context);
    if (center == null) return const SizedBox.shrink();
    final urgent = [
      for (final n in center.items)
        if ((n.tone == NoticeTone.action || n.tone == NoticeTone.warning) &&
            !n.id.startsWith('face:'))
          n,
    ].take(3).toList();
    if (urgent.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Panel(
        padding: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Needs your attention',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/notifications'),
                  child: const Text('See all'),
                ),
              ],
            ),
            for (final n in urgent)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  center.markRead(n);
                  if (n.route != null) context.go(n.route!);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        n.icon,
                        color: n.tone == NoticeTone.warning
                            ? studentAmber
                            : scheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          n.title,
                          style: TextStyle(
                            fontWeight: center.isUnread(n)
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
