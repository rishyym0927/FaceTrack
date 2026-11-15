import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'attendance_overview.dart';
import 'biometric_reviews.dart';
import 'teacher_sessions.dart';
import 'teacher_disputes.dart';
import 'teacher_notifications.dart';

class TeacherClasses extends ConsumerStatefulWidget {
  const TeacherClasses({super.key});
  @override
  ConsumerState<TeacherClasses> createState() => _TeacherClassesState();
}

class _TeacherClassesState extends ConsumerState<TeacherClasses>
    with ResumeRefresh<TeacherClasses> {
  late final ApiClient api;
  late final String institute;
  late final PagedController<Offering> controller;
  bool preparing = false;

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    controller = PagedController(
      (cursor) => api.offerings(institute, cursor: cursor),
    );
    controller.load();
    watchLifecycle();
  }

  @override
  void refreshOnResume() {
    refreshAll();
  }

  Future<void> refreshAll() async {
    await controller.load();
  }

  @override
  void dispose() {
    unwatchLifecycle();
    controller.dispose();
    super.dispose();
  }

  Future<void> create() async {
    setState(() => preparing = true);
    try {
      final lists = await Future.wait(
        [
          'courses',
          'terms',
          'class-groups',
        ].map((kind) => api.academics(institute, kind)),
      );
      if (!mounted) return;
      if (lists.any((list) => list.isEmpty)) {
        showMessage(
          context,
          'Academic setup is incomplete. Contact your institute.',
        );
        return;
      }
      String? course, term, group;
      if (lists[1].length == 1) term = lists[1].first.id;
      await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, setLocal) => ActionDialog(
            title: 'Add a subject',
            button: 'Add subject',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Choose the subject, semester term and section. You will be assigned as its faculty.',
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  initialValue: course,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Subject'),
                  items: [
                    for (final x in lists[0])
                      DropdownMenuItem(
                        value: x.id,
                        child: Text(x.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (x) => setLocal(() => course = x),
                  validator: requiredText,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: term,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Semester term'),
                  items: [
                    for (final x in lists[1])
                      DropdownMenuItem(
                        value: x.id,
                        child: Text(x.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (x) => setLocal(() {
                    term = x;
                    group = null;
                  }),
                  validator: requiredText,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey(term),
                  initialValue: group,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Section'),
                  items: [
                    for (final x in lists[2].where((g) => g.termId == term))
                      DropdownMenuItem(
                        value: x.id,
                        child: Text(x.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: term == null
                      ? null
                      : (x) => setLocal(() => group = x),
                  validator: requiredText,
                ),
              ],
            ),
            submit: (mutation) async {
              await api.send(
                'POST',
                '/v1/offerings',
                institute: institute,
                body: {
                  'course_id': course,
                  'term_id': term,
                  'class_group_id': group,
                },
                mutation: mutation,
              );
            },
          ),
        ),
      );
      if (mounted) await refreshAll();
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e is AppFailure
              ? e.message
              : 'Could not load academic choices. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> open(String id) async {
    await context.push('/classes/$id');
  }

  @override
  Widget build(BuildContext context) {
    return ContentPage(
      onRefresh: refreshAll,
      children: [
        PageHeader(
          title: 'Subjects',
          action: Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: preparing ? null : create,
                icon: const Icon(Icons.add),
                label: Text(preparing ? 'Loading…' : 'Add subject'),
              ),
              IconButton(
                tooltip: 'Refresh subjects',
                onPressed: refreshAll,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        PagedList(
          controller: controller,
          emptyTitle: 'No assigned subjects',
          emptyMessage: 'Add a subject or ask your institute to assign one.',
          item: (Offering o) => SubjectTile(
            icon: Icons.class_outlined,
            title: o.title,
            subtitle: o.subtitle,
            note: o.termTitle,
            onTap: () => open(o.id),
          ),
        ),
      ],
    );
  }
}

class TeacherClassDetail extends ConsumerStatefulWidget {
  const TeacherClassDetail({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TeacherClassDetail> createState() => _TeacherClassDetailState();
}

class _TeacherClassDetailState extends ConsumerState<TeacherClassDetail>
    with ResumeRefresh<TeacherClassDetail> {
  late final ApiClient api;
  late final String institute;
  late final PagedController<Enrollment> requests, students, pendingFaces;
  late final PagedController<BiometricAttempt> faces;
  int tab = 3;
  final visited = <int>{};
  final dirty = <int>{};
  final versions = <int, int>{};
  final panels = <int, Widget>{};
  final scroll = ScrollController();
  final offsets = <int, double>{};
  int scrollGeneration = 0;
  int _recordGeneration = 0;
  Offering? offering;
  Object? recordError;
  bool workFailed = false;
  static const _tabNames = <String, int>{
    'sessions': 3,
    'students': 1,
    'face-reviews': 2,
    'queries': 4,
    'overview': 5,
  };

  int get _routeTab =>
      _tabNames[GoRouterState.of(context).uri.queryParameters['tab']] ?? 3;
  bool loadingCode = false;

  /// Pending work per tab, shown as counts on the tab chips.
  SubjectWork? work;
  int _workGeneration = 0;

  Future<void> _loadWork() async {
    final generation = ++_workGeneration;
    try {
      final w = await loadSubjectWork(api, institute, widget.id);
      if (mounted && generation == _workGeneration) {
        setState(() {
          work = w;
          workFailed = false;
        });
      }
    } catch (error) {
      if (!mounted || generation != _workGeneration) return;
      if (_accessLost(error)) {
        _clearSubject(error);
      } else {
        setState(() => workFailed = true);
      }
    }
  }

  int get _toReview => work?.sessionsToReview ?? 0;

  bool _accessLost(Object error) =>
      error is AppFailure && const {401, 403, 404}.contains(error.status);

  void _clearSubject(Object error) {
    ++_recordGeneration;
    ++_workGeneration;
    for (final controller in [requests, students, pendingFaces, faces]) {
      controller.clear();
    }
    setState(() {
      offering = null;
      recordError = error;
      work = null;
      visited.clear();
      panels.clear();
      dirty.clear();
      offsets.clear();
    });
  }

  Future<void> _loadRecord() async {
    final generation = ++_recordGeneration;
    try {
      final result = await api.offering(institute, widget.id);
      if (!mounted || generation != _recordGeneration) return;
      setState(() {
        offering = result;
        recordError = null;
      });
      _activate(tab);
    } catch (error) {
      if (!mounted || generation != _recordGeneration) return;
      if (_accessLost(error)) {
        _clearSubject(error);
      } else {
        setState(() => recordError = error);
      }
    }
  }

  int _count(int tab) => switch (tab) {
    3 => _toReview,
    1 => work?.joinRequests ?? 0,
    2 => work?.faceReviews ?? 0,
    4 => work?.openQueries ?? 0,
    _ => 0,
  };

  static const _tabs = [
    (
      3,
      'Sessions',
      Icons.event_note_outlined,
      'Create a session, capture the classroom and review attendance before publishing.',
    ),
    (
      1,
      'Students',
      Icons.groups_outlined,
      'Approve subject requests and check who still needs face enrolment.',
    ),
    (
      2,
      'Face reviews',
      Icons.face_retouching_natural_outlined,
      'Check each recording before activating face enrolment. Subject membership is approved separately.',
    ),
    (
      4,
      'Queries',
      Icons.forum_outlined,
      'Students question published Absent results here. Accepting one publishes a correction.',
    ),
    (
      5,
      'Overview',
      Icons.insights_outlined,
      'Cumulative attendance across every published class for this subject.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    requests = PagedController(
      (cursor) => api.roster(institute, widget.id, 'requested', cursor: cursor),
    );
    students = PagedController(
      (cursor) => api.roster(institute, widget.id, 'active', cursor: cursor),
    );
    pendingFaces = PagedController(
      (cursor) =>
          api.roster(institute, widget.id, 'pending_face', cursor: cursor),
    );
    faces = PagedController(
      (cursor) async => PageData.fromJson(
        await api.send(
          'GET',
          '/v1/offerings/${widget.id}/biometric-enrollments',
          institute: institute,
          query: {'cursor': ?cursor},
        ),
        BiometricAttempt.fromJson,
      ),
    );
    unawaited(_loadRecord());
    unawaited(_loadWork());
    watchLifecycle();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _activate(_routeTab);
  }

  @override
  void didUpdateWidget(TeacherClassDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _activate(_routeTab);
  }

  Future<void> refresh() => ApiClient.freshReads(() async {
    if (!mounted) return;
    dirty.addAll(visited);
    await Future.wait([_loadRecord(), _loadWork()]);
  });

  void _activate(int next) {
    final changed = next != tab;
    if (changed && scroll.hasClients) offsets[tab] = scroll.offset;
    tab = next;
    if (changed) {
      final generation = ++scrollGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != scrollGeneration || !scroll.hasClients) {
          return;
        }
        scroll.jumpTo(
          (offsets[next] ?? 0).clamp(0.0, scroll.position.maxScrollExtent),
        );
      });
    }
    if (offering == null) return;
    final first = visited.add(next);
    final stale = dirty.remove(next);
    if (!first && !stale) return;
    if (next == 1 || next == 2) {
      unawaited(
        ApiClient.freshReads(() async {
          final controllers = next == 1
              ? [requests, students, pendingFaces]
              : [faces];
          await Future.wait(controllers.map((controller) => controller.load()));
          if (!mounted) return;
          for (final controller in controllers) {
            final error = controller.error;
            if (error != null && _accessLost(error)) {
              _clearSubject(error);
              break;
            }
          }
        }),
      );
    } else if (stale) {
      versions[next] = (versions[next] ?? 0) + 1;
      panels.remove(next);
    }
  }

  void _selectTab(int next) {
    if (next == tab) return;
    final name = _tabNames.entries
        .firstWhere((entry) => entry.value == next)
        .key;
    final current = GoRouterState.of(context).uri;
    setState(() => _activate(next));
    context.replace(
      current
          .replace(queryParameters: {...current.queryParameters, 'tab': name})
          .toString(),
    );
  }

  void _changed(Set<int> tabs) {
    if (!mounted) return;
    setState(() {
      dirty.addAll(tabs.where(visited.contains));
      _activate(tab);
    });
    unawaited(ApiClient.freshReads(_loadWork));
  }

  @override
  void refreshOnResume() {
    if (ModalRoute.isCurrentOf(context) == true) unawaited(refresh());
  }

  @override
  void dispose() {
    unwatchLifecycle();
    scroll.dispose();
    requests.dispose();
    students.dispose();
    pendingFaces.dispose();
    faces.dispose();
    super.dispose();
  }

  Future<void> review(Enrollment entry, bool approve) async {
    final reason = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: approve ? 'Approve student?' : 'Decline request',
        button: approve ? 'Approve' : 'Decline',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              entry.name ?? 'Student',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(entry.number ?? ''),
            const SizedBox(height: 16),
            if (approve)
              const Text(
                'Confirm this student belongs to this subject and section. This approves subject membership only.',
              )
            else
              TextFormField(
                controller: reason,
                maxLength: 500,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Reason for declining',
                ),
                validator: requiredText,
              ),
          ],
        ),
        submit: (mutation) async {
          await api.send(
            'PATCH',
            '/v1/offerings/${widget.id}/enrollments/${entry.id}',
            institute: institute,
            body: {
              'status': approve ? 'active' : 'rejected',
              'reason': approve
                  ? 'Verified subject membership'
                  : reason.text.trim(),
            },
            mutation: mutation,
            version: entry.version,
          );
        },
      ),
    );
    reason.dispose();
    if (saved == true) _changed({1, 2});
  }

  Future<void> code() async {
    setState(() => loadingCode = true);
    try {
      JoinCode? value;
      try {
        value = await api.code(institute, widget.id);
      } on AppFailure catch (e) {
        if (e.code != 'JOIN_CODE_UNAVAILABLE') rethrow;
      }
      if (!mounted) return;
      final existing = value;
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Subject join code'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (existing == null)
                  const Text(
                    'Create a code to let students request membership.',
                  )
                else ...[
                  SelectableText(
                    existing.code,
                    style: Theme.of(c).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Expires on ${existing.expires.toLocal().toString().split('.').first} (local time).',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Sharing a code allows a request. Students still need your approval.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Close'),
            ),
            if (existing != null)
              TextButton(
                onPressed: () async {
                  try {
                    await Clipboard.setData(ClipboardData(text: existing.code));
                    if (c.mounted) showMessage(c, 'Code copied.');
                  } catch (_) {
                    if (c.mounted) {
                      showMessage(
                        c,
                        'Could not copy. Select the code to copy it manually.',
                      );
                    }
                  }
                },
                child: const Text('Copy code'),
              ),
            OutlinedButton(
              onPressed: () => Navigator.pop(c, 'change'),
              child: Text(existing == null ? 'Create code' : 'Rotate code'),
            ),
          ],
        ),
      );
      if (choice == 'change' && mounted) {
        final latest = await api.offering(institute, widget.id);
        if (!mounted) return;
        final saved = await showDialog<bool>(
          context: context,
          builder: (_) => ActionDialog(
            title: existing == null ? 'Create join code?' : 'Rotate join code?',
            button: existing == null ? 'Create' : 'Rotate',
            child: Text(
              existing == null
                  ? 'Students can use this code to request subject membership.'
                  : 'The previous code will stop accepting new requests. Existing memberships are preserved.',
            ),
            submit: (mutation) async {
              await api.send(
                'POST',
                '/v1/offerings/${widget.id}/join-code',
                institute: institute,
                mutation: mutation,
                version: latest.version,
              );
            },
          ),
        );
        if (mounted) await refresh();
        if (saved == true && mounted) await code();
      }
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e is AppFailure
              ? e.message
              : 'Could not load the join code. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => loadingCode = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = offering;
    if (o == null) {
      return ContentPage(
        onRefresh: refresh,
        children: recordError == null
            ? const [SkeletonCard(), SkeletonList()]
            : [ErrorView(recordError!, retry: refresh)],
      );
    }
    final current = _tabs.firstWhere((t) => t.$1 == tab);
    return ContentPage(
      onRefresh: refresh,
      controller: scroll,
      children: [
        if (recordError != null) ErrorView(recordError!, retry: refresh),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => goBack(context, '/classes'),
            icon: const Icon(Icons.arrow_back),
            label: const Text('All subjects'),
          ),
        ),
        _SubjectHero(
          offering: o,
          loadingCode: loadingCode,
          onJoinCode: code,
          onRefresh: refresh,
        ),
        _AttentionStrip(
          items: [
            if (_toReview > 0)
              (
                Icons.rate_review_outlined,
                '$_toReview ${_toReview == 1 ? 'session' : 'sessions'} to review',
                3,
              ),
            if ((work?.joinRequests ?? 0) > 0)
              (
                Icons.person_add_alt,
                '${work!.joinRequests} join ${work!.joinRequests == 1 ? 'request' : 'requests'}',
                1,
              ),
            if ((work?.faceReviews ?? 0) > 0)
              (
                Icons.face_outlined,
                '${work!.faceReviews} face ${work!.faceReviews == 1 ? 'review' : 'reviews'}',
                2,
              ),
            if ((work?.openQueries ?? 0) > 0)
              (
                Icons.forum_outlined,
                '${work!.openQueries} open ${work!.openQueries == 1 ? 'query' : 'queries'}',
                4,
              ),
          ],
          loaded: work != null || workFailed,
          failed: workFailed ? const ['subject work'] : const [],
          onRetry: () => ApiClient.freshReads(_loadWork),
          onOpen: _selectTab,
        ),
        const SizedBox(height: 20),
        _SubjectTabs(
          tabs: [for (final t in _tabs) (t.$1, t.$2, t.$3, _count(t.$1))],
          selected: tab,
          onSelect: _selectTab,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                current.$4,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        for (final entry in _tabs)
          if (visited.contains(entry.$1))
            Offstage(
              key: ValueKey(entry.$1),
              offstage: entry.$1 != tab,
              child: TickerMode(
                enabled: entry.$1 == tab,
                child: ExcludeFocus(
                  excluding: entry.$1 != tab,
                  child: panels.putIfAbsent(entry.$1, () => _tabBody(entry.$1)),
                ),
              ),
            ),
      ],
    );
  }

  Widget _tabBody(int panel) => switch (panel) {
    3 => TeacherSessions(
      api: api,
      institute: institute,
      offering: widget.id,
      publishableKey: ref.read(servicesProvider).config.publishableKey,
      version: versions[panel] ?? 0,
      changed: () => _changed({5}),
      onAccessLost: _clearSubject,
    ),
    2 => BiometricReviews(
      controller: faces,
      api: api,
      institute: institute,
      changed: () => _changed({1, 2}),
    ),
    4 => TeacherDisputes(
      api: api,
      institute: institute,
      offering: widget.id,
      version: versions[panel] ?? 0,
      changed: (accepted) => _changed({if (accepted) 5}),
      onAccessLost: _clearSubject,
    ),
    5 => AttendanceOverview(
      api: api,
      institute: institute,
      offering: widget.id,
      version: versions[panel] ?? 0,
      onAccessLost: _clearSubject,
    ),
    _ => _students(),
  };

  Widget _students() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AnimatedBuilder(
        animation: requests,
        builder: (context, _) {
          final pending = requests.items;
          if (pending.isEmpty) {
            return requests.loading
                ? const SizedBox.shrink()
                : requests.error != null
                ? ErrorView(requests.error!, retry: requests.retry)
                : const _InlineNote(
                    icon: Icons.check_circle_outline,
                    text: 'No join requests are waiting. Share the join code so students can request to join.',
                  );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionTitle(
                'Waiting for approval · ${pending.length}${requests.cursor != null ? '+' : ''}',
              ),
              for (final e in pending)
                _PersonRow(
                  enrollment: e,
                  highlight: true,
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => review(e, false),
                        child: const Text('Decline'),
                      ),
                      FilledButton(
                        onPressed: () => review(e, true),
                        child: const Text('Approve'),
                      ),
                    ],
                  ),
                ),
              if (requests.cursor != null)
                TextButton(
                  onPressed: () => requests.load(reset: false),
                  child: const Text('Load more requests'),
                ),
            ],
          );
        },
      ),
      const SectionTitle('Approved students'),
      PagedList(
        controller: students,
        emptyTitle: 'No approved students',
        emptyMessage:
            'Students appear here after subject and face enrolment approval.',
        item: (Enrollment e) =>
            _PersonRow(enrollment: e, trailing: const StatusBadge('active')),
      ),
      const SectionTitle('Pending face enrolment'),
      PagedList(
        controller: pendingFaces,
        emptyTitle: 'No students pending face enrolment',
        emptyMessage:
            'Everyone with subject approval has completed face enrolment.',
        item: (entry) =>
            _PersonRow(enrollment: entry, trailing: const SizedBox.shrink()),
      ),
    ],
  );
}

class _SubjectHero extends StatelessWidget {
  const _SubjectHero({
    required this.offering,
    required this.loadingCode,
    required this.onJoinCode,
    required this.onRefresh,
  });

  final Offering offering;
  final bool loadingCode;
  final VoidCallback onJoinCode;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => PageHeader(
    title: offering.title,
    subtitle: '${offering.subtitle} · ${offering.termTitle}',
    action: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: loadingCode ? null : onJoinCode,
          icon: const Icon(Icons.key_outlined),
          label: const Text('Join code'),
        ),
        IconButton(
          tooltip: 'Refresh subject',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );
}

/// Pending work across tabs, each a shortcut to the tab that handles it.
class _AttentionStrip extends StatelessWidget {
  const _AttentionStrip({
    required this.items,
    required this.loaded,
    required this.failed,
    required this.onRetry,
    required this.onOpen,
  });
  final List<(IconData, String, int)> items;
  final bool loaded;
  final List<String> failed;
  final VoidCallback onRetry;
  final ValueChanged<int> onOpen;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget child;
    if (!loaded) {
      child = const SizedBox.shrink();
    } else if (items.isEmpty && failed.isEmpty) {
      child = const _InlineNote(
        icon: Icons.check_circle_outline,
        text: 'All caught up: nothing is waiting for you in this subject.',
      );
    } else {
      child = Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (items.isNotEmpty)
            Text(
              'Needs you',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          for (final (icon, label, tab) in items)
            ActionChip(
              avatar: Icon(icon, size: 18, color: const Color(0xff9a6a00)),
              label: Text(label),
              backgroundColor: const Color(0xfffff4dc),
              side: const BorderSide(color: Color(0xfff0d9a6)),
              onPressed: () => onOpen(tab),
            ),
          if (failed.isNotEmpty)
            _InlineNote(
              icon: Icons.info_outline,
              text: 'Could not load ${failed.join(', ')}.',
            ),
          if (failed.isNotEmpty)
            TextButton(onPressed: onRetry, child: const Text('Retry counts')),
        ],
      );
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.only(top: loaded ? 16 : 0),
        child: child,
      ),
    );
  }
}

/// Icon tabs with counts; scrolls sideways on narrow screens.
class _SubjectTabs extends StatefulWidget {
  const _SubjectTabs({
    required this.tabs,
    required this.selected,
    required this.onSelect,
  });
  final List<(int, String, IconData, int)> tabs;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  State<_SubjectTabs> createState() => _SubjectTabsState();
}

class _SubjectTabsState extends State<_SubjectTabs> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(_SubjectTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _revealSelected();
  }

  void _revealSelected() {
    final selected = widget.selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || selected != widget.selected || !_scroll.hasClients) {
        return;
      }
      final render = _keys[selected]?.currentContext?.findRenderObject();
      if (render == null) return;
      final duration = MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150);
      _scroll.position.ensureVisible(render, alignment: .5, duration: duration);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      padding: 6,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _scroll,
        child: Row(
          children: [
            for (final (id, label, icon, count) in widget.tabs)
              Padding(
                padding: const EdgeInsets.all(2),
                child: Semantics(
                  key: _keys.putIfAbsent(id, GlobalKey.new),
                  button: true,
                  selected: id == widget.selected,
                  label: count > 0 ? '$label, $count waiting' : label,
                  onTap: () => widget.onSelect(id),
                  child: ExcludeSemantics(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => widget.onSelect(id),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: id == widget.selected
                                ? scheme.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icon,
                                size: 20,
                                color: id == widget.selected
                                    ? Colors.white
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                label,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: id == widget.selected
                                      ? Colors.white
                                      : scheme.onSurface,
                                ),
                              ),
                              if (count > 0) ...[
                                const SizedBox(width: 8),
                                Badge(
                                  label: Text('$count'),
                                  backgroundColor: const Color(0xff9a6a00),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.enrollment,
    required this.trailing,
    this.highlight = false,
  });
  final Enrollment enrollment;
  final Widget trailing;
  final bool highlight;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = enrollment.name ?? 'Student';
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xfffffaf0) : scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight ? const Color(0xfff0d9a6) : scheme.outlineVariant,
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: scheme.primary.withValues(alpha: .10),
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Enrolment number: ${enrollment.number ?? '—'}',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          trailing,
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xff176451)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}

/// What a subject needs from its faculty, and its next class, as chips.
class SubjectWorkChips extends StatelessWidget {
  const SubjectWorkChips({super.key, required this.work, this.now});
  final SubjectWork work;
  final DateTime? now;

  static const _amber = Color(0xff9a6a00), _green = Color(0xff176451);

  @override
  Widget build(BuildContext context) {
    final w = work, l = MaterialLocalizations.of(context);
    final toReview = w.sessions
        .where(
          (s) => const {
            'closed',
            'review_required',
            'no_data',
          }.contains(s['status']),
        )
        .length;
    final at = now ?? DateTime.now();
    DateTime? next;
    for (final s in w.sessions) {
      if (!const {'scheduled', 'open'}.contains(s['status'])) continue;
      final start = DateTime.parse(s['starts_at'] as String).toLocal();
      final end = s['ends_at'] is String
          ? DateTime.parse(s['ends_at'] as String).toLocal()
          : start;
      if (end.isBefore(at)) continue;
      if (next == null || start.isBefore(next)) next = start;
    }
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    final pending = [
      if (toReview > 0)
        (
          Icons.rate_review_outlined,
          n(toReview, 'session to review', 'sessions to review'),
        ),
      if (w.joinRequests > 0)
        (
          Icons.person_add_alt,
          n(w.joinRequests, 'join request', 'join requests'),
        ),
      if (w.faceReviews > 0)
        (Icons.face_outlined, n(w.faceReviews, 'face review', 'face reviews')),
      if (w.openQueries > 0)
        (Icons.forum_outlined, n(w.openQueries, 'open query', 'open queries')),
    ];
    Widget chip(IconData icon, String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              text,
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
    );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (icon, text) in pending) chip(icon, text, _amber),
        if (pending.isEmpty && w.failed.isEmpty)
          chip(Icons.check_circle_outline, 'All caught up', _green),
        if (next != null)
          chip(
            Icons.event_outlined,
            'Next class: ${l.formatShortDate(next)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(next))}',
            Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}
