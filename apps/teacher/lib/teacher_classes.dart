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
          subtitle:
              'Open a subject to start a class session, review attendance and manage students.',
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
        _SubjectsList(
          controller: controller,
          onOpen: open,
          onAdd: preparing ? null : create,
        ),
      ],
    );
  }
}

/// Palette for subject accents: dark enough for white text and a soft tint.
const _accents = <Color>[
  Color(0xff176451),
  Color(0xff1f5f8b),
  Color(0xff6a4c93),
  Color(0xffb0562f),
  Color(0xff9a6a00),
  Color(0xff2a7f8f),
  Color(0xff8e3b6b),
  Color(0xff4a6a2a),
];

/// A subject's accent colour, derived only from its code so the same subject
/// looks the same everywhere and on every platform. The fold stays below
/// 2^36, so it is identical on the VM and in JavaScript.
Color subjectAccent(String code) {
  var h = 7;
  for (final unit in code.trim().toUpperCase().codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return _accents[h % _accents.length];
}

/// Letters of a subject code ("BAS 201" becomes "BAS") for its tile.
String subjectGlyph(String code) {
  final letters = code.replaceAll(RegExp('[^A-Za-z]'), '').toUpperCase();
  return letters.length > 3 ? letters.substring(0, 3) : letters;
}

class _SubjectGlyph extends StatelessWidget {
  const _SubjectGlyph(this.code, this.accent, {this.size = 48});
  final String code;
  final Color accent;
  final double size;
  @override
  Widget build(BuildContext context) {
    final glyph = subjectGlyph(code);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(AppSpace.xs),
        decoration: BoxDecoration(
          color: AppTone.tint(accent, .12),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        alignment: Alignment.center,
        child: glyph.isEmpty
            ? Icon(Icons.class_outlined, color: accent)
            : FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  glyph,
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: .4,
                  ),
                ),
              ),
      ),
    );
  }
}

/// "Section CSE1 · 3rd Semester · CSE": where a subject sits, without the
/// code (the code is shown on its own line).
String subjectWhere(Offering o) => [
  if (o.section.isNotEmpty && o.section != 'ALL') 'Section ${o.section}',
  semesterLabel(o.semester),
  if (o.branch.isNotEmpty) o.branch,
].join(' · ');

String _statusText(String status) => status.isEmpty
    ? 'Unknown'
    : status == 'active'
    ? 'Active'
    : '${status[0].toUpperCase()}${status.substring(1).replaceAll('_', ' ')}';

/// One subject in the Subjects tab: accent bar, code, name, where it sits and
/// a short status row. Shows only what the list already carries.
class SubjectCard extends StatelessWidget {
  const SubjectCard({
    super.key,
    required this.offering,
    required this.onTap,
    this.needsAttention = false,
  });
  final Offering offering;
  final VoidCallback onTap;
  final bool needsAttention;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme, o = offering;
    final accent = subjectAccent(o.courseCode);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 5,
              child: ColoredBox(color: accent),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg + 5,
                AppSpace.lg,
                AppSpace.md,
                AppSpace.lg,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SubjectGlyph(o.courseCode, accent),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          o.courseCode,
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                            letterSpacing: .6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          o.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontSize: 16.5, height: 1.25),
                        ),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          subjectWhere(o),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: AppSpace.md),
                        Wrap(
                          spacing: AppSpace.sm,
                          runSpacing: AppSpace.sm,
                          children: [
                            TonePill(
                              o.termTitle,
                              tone: AppTone.info,
                              icon: Icons.calendar_today_outlined,
                            ),
                            TonePill(
                              _statusText(o.status),
                              tone: o.status == 'active'
                                  ? AppTone.success
                                  : AppTone.neutral,
                            ),
                            if (needsAttention)
                              const TonePill(
                                'Needs attention',
                                tone: AppTone.warning,
                                icon: Icons.priority_high,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.md),
                    child: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
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

class _SubjectSkeleton extends StatelessWidget {
  const _SubjectSkeleton();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.lg),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkelBox(width: 48, height: 48, radius: AppRadius.md),
        SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkelBox(width: 64, height: 11),
              SizedBox(height: 10),
              SkelBox(height: 16),
              SizedBox(height: 10),
              SkelBox(width: 160, height: 12),
              SizedBox(height: 14),
              Row(
                children: [
                  SkelBox(width: 110, height: 24, radius: AppRadius.pill),
                  SizedBox(width: AppSpace.sm),
                  SkelBox(width: 60, height: 24, radius: AppRadius.pill),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The subject cards with loading, empty and error states. One column on
/// phones, two or three on wide screens.
class _SubjectsList extends StatelessWidget {
  const _SubjectsList({
    required this.controller,
    required this.onOpen,
    required this.onAdd,
  });
  final PagedController<Offering> controller;
  final ValueChanged<String> onOpen;
  final VoidCallback? onAdd;

  /// Subjects with an action or warning notice already loaded for the bell.
  /// Reads the existing notices only; makes no request.
  Set<String> _attention(BuildContext context) {
    final center = NotificationScope.of(context);
    if (center == null) return const {};
    return {
      for (final n in center.items)
        if ((n.tone == NoticeTone.action || n.tone == NoticeTone.warning) &&
            (n.route ?? '').startsWith('/classes/'))
          n.route!.substring('/classes/'.length).split('?').first,
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final Widget content;
      if (controller.loading && controller.items.isEmpty) {
        content = Column(
          key: const ValueKey('loading'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 3; i++)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpace.md),
                child: _SubjectSkeleton(),
              ),
          ],
        );
      } else if (controller.error != null && controller.items.isEmpty) {
        content = KeyedSubtree(
          key: const ValueKey('error'),
          child: ErrorView(controller.error!, retry: () => controller.load()),
        );
      } else if (controller.items.isEmpty) {
        content = EmptyState(
          key: const ValueKey('empty'),
          icon: Icons.class_outlined,
          title: 'No subjects yet',
          message:
              'Add a subject to start taking attendance, or ask your institute to assign one to you.',
          action: onAdd == null
              ? null
              : FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                  label: const Text('Add your first subject'),
                ),
        );
      } else {
        final attention = _attention(context);
        content = Column(
          key: const ValueKey('items'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.loading) const LinearProgressIndicator(),
            LayoutBuilder(
              builder: (context, box) {
                final columns = (box.maxWidth / 380).floor().clamp(1, 3);
                final width =
                    (box.maxWidth - AppSpace.md * (columns - 1)) / columns;
                return Wrap(
                  spacing: AppSpace.md,
                  runSpacing: AppSpace.md,
                  children: [
                    for (final o in controller.items)
                      SizedBox(
                        width: width,
                        child: SubjectCard(
                          offering: o,
                          needsAttention: attention.contains(o.id),
                          onTap: () => onOpen(o.id),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.md),
                child: ErrorView(
                  controller.error!,
                  retry: () => controller.retry(),
                ),
              ),
            if (controller.cursor != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.md),
                child: Align(
                  child: OutlinedButton(
                    onPressed: controller.loading
                        ? null
                        : () => controller.load(reset: false),
                    child: const Text('Load more'),
                  ),
                ),
              ),
          ],
        );
      }
      return AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: content,
      );
    },
  );
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
    for (final controller in [requests, students, pendingFaces, faces]) {
      controller.addListener(() {
        final error = controller.error;
        if (error != null && _accessLost(error)) _clearSubject(error);
      });
    }
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
    disposeAfterDialog(reason);
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
    final accent = subjectAccent(o.courseCode);
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
        ListenableBuilder(
          listenable: students,
          builder: (context, _) => _SubjectHero(
            offering: o,
            accent: accent,
            studentCount: students.items.isEmpty
                ? null
                : '${students.items.length}${students.cursor != null ? '+' : ''}',
            loadingCode: loadingCode,
            onJoinCode: code,
            onRefresh: refresh,
            onOpenSessions: tab == 3 ? null : () => _selectTab(3),
          ),
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
        const SizedBox(height: AppSpace.xl),
        _SubjectTabs(
          tabs: [for (final t in _tabs) (t.$1, t.$2, t.$3, _count(t.$1))],
          selected: tab,
          accent: accent,
          onSelect: _selectTab,
        ),
        const SizedBox(height: AppSpace.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  current.$4,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.lg),
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
                    text:
                        'No join requests are waiting. Share the join code so students can request to join.',
                  );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GroupTitle(
                'Waiting for approval · ${pending.length}${requests.cursor != null ? '+' : ''}',
                tone: AppTone.warning,
              ),
              for (final e in pending)
                _PersonRow(
                  enrollment: e,
                  highlight: true,
                  pill: const TonePill(
                    'Awaiting approval',
                    tone: AppTone.warning,
                    icon: Icons.hourglass_top_outlined,
                  ),
                  actions: Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.sm,
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
      ListenableBuilder(
        listenable: students,
        builder: (context, _) => _GroupTitle(
          'Approved students',
          count: students.items.isEmpty
              ? null
              : '${students.items.length}${students.cursor != null ? '+' : ''}',
        ),
      ),
      PagedList(
        controller: students,
        emptyTitle: 'No approved students',
        emptyMessage:
            'Students appear here after subject and face enrolment approval.',
        item: (Enrollment e) => _PersonRow(
          enrollment: e,
          pill: const TonePill(
            'Approved',
            tone: AppTone.success,
            icon: Icons.check_circle_outline,
          ),
        ),
      ),
      ListenableBuilder(
        listenable: pendingFaces,
        builder: (context, _) => _GroupTitle(
          'Pending face enrolment',
          count: pendingFaces.items.isEmpty
              ? null
              : '${pendingFaces.items.length}${pendingFaces.cursor != null ? '+' : ''}',
        ),
      ),
      ListenableBuilder(
        listenable: pendingFaces,
        builder: (context, _) =>
            pendingFaces.items.isEmpty &&
                !pendingFaces.loading &&
                pendingFaces.error == null
            ? const _InlineNote(
                icon: Icons.check_circle_outline,
                text:
                    'Everyone with subject approval has completed face enrolment.',
              )
            : PagedList(
                controller: pendingFaces,
                emptyTitle: 'No students pending face enrolment',
                emptyMessage:
                    'Everyone with subject approval has completed face enrolment.',
                item: (entry) => _PersonRow(
                  enrollment: entry,
                  pill: const TonePill(
                    'Face enrolment pending',
                    tone: AppTone.warning,
                    icon: Icons.face_outlined,
                  ),
                ),
              ),
      ),
    ],
  );
}

/// Heading for a group of people, with an optional count badge.
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text, {this.count, this.tone});
  final String text;
  final String? count;
  final Color? tone;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpace.xl,
        bottom: AppSpace.md,
      ),
      child: Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            header: true,
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: tone ?? scheme.onSurface,
              ),
            ),
          ),
          if (count != null)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                count!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SubjectHero extends StatelessWidget {
  const _SubjectHero({
    required this.offering,
    required this.accent,
    required this.loadingCode,
    required this.onJoinCode,
    required this.onRefresh,
    required this.onOpenSessions,
    this.studentCount,
  });

  final Offering offering;
  final Color accent;

  /// Approved students, only once the roster has been loaded (never guessed).
  final String? studentCount;
  final bool loadingCode;
  final VoidCallback onJoinCode;
  final Future<void> Function() onRefresh;

  /// Jumps to the Sessions tab, where a session is created; null when already there.
  final VoidCallback? onOpenSessions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme, o = offering;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 5, color: accent),
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SubjectGlyph(o.courseCode, accent, size: 52),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              o.title,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            o.subtitle,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    TonePill(
                      o.termTitle,
                      tone: AppTone.info,
                      icon: Icons.calendar_today_outlined,
                    ),
                    TonePill(
                      _statusText(o.status),
                      tone: o.status == 'active'
                          ? AppTone.success
                          : AppTone.neutral,
                    ),
                    if (studentCount != null)
                      TonePill(
                        studentCount == '1'
                            ? '1 student enrolled'
                            : '$studentCount students enrolled',
                        tone: AppTone.success,
                        icon: Icons.groups_outlined,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.lg),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (onOpenSessions != null)
                      FilledButton.icon(
                        onPressed: onOpenSessions,
                        icon: const Icon(Icons.event_available_outlined),
                        label: const Text('Open sessions'),
                      ),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
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
        spacing: AppSpace.sm + 2,
        runSpacing: AppSpace.sm + 2,
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
              avatar: Icon(icon, size: 18, color: AppTone.warning),
              label: Text(label),
              backgroundColor: const Color(0xfffff4dc),
              side: const BorderSide(color: Color(0xfff0d9a6)),
              onPressed: () => onOpen(tab),
            ),
          if (failed.isNotEmpty)
            _InlineNote(
              icon: Icons.info_outline,
              text: 'Could not load ${failed.join(', ')}.',
              tone: AppTone.warning,
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
        padding: EdgeInsets.only(top: loaded ? AppSpace.lg : 0),
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
    required this.accent,
    required this.onSelect,
  });
  final List<(int, String, IconData, int)> tabs;
  final int selected;
  final Color accent;
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
      padding: AppSpace.xs + 2,
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
                        borderRadius: BorderRadius.circular(AppRadius.md),
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
                                ? widget.accent
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(AppRadius.md),
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
    required this.pill,
    this.actions,
    this.highlight = false,
  });
  final Enrollment enrollment;

  /// Enrolment status, always shown under the name so it wraps safely.
  final Widget pill;

  /// Approve / decline buttons for a request.
  final Widget? actions;
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
    final tone = highlight ? AppTone.warning : scheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md + 2),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xfffffaf0) : scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: highlight ? const Color(0xfff0d9a6) : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: tone.withValues(alpha: .12),
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  style: TextStyle(fontWeight: FontWeight.w800, color: tone),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Enrolment number: ${enrollment.number ?? '—'}',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Align(alignment: Alignment.centerLeft, child: pill),
                  ],
                ),
              ),
            ],
          ),
          if (actions != null) ...[
            const SizedBox(height: AppSpace.md),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote({
    required this.icon,
    required this.text,
    this.tone = AppTone.success,
  });
  final IconData icon;
  final String text;
  final Color tone;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppTone.tint(tone, .07),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: tone),
          const SizedBox(width: AppSpace.sm + 2),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ),
        ],
      ),
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
