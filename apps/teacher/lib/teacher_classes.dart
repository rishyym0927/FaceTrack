import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'attendance_overview.dart';
import 'biometric_reviews.dart';
import 'teacher_sessions.dart';
import 'teacher_dashboard.dart';
import 'teacher_disputes.dart';

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
  int dashboardTick = 0;
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
    if (mounted) setState(() => dashboardTick++);
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
    if (mounted) await refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    String? name;
    for (final t in auth.account?.teachers ?? const <Person>[]) {
      if (t.instituteId == institute) name = firstName(t.name);
    }
    return ContentPage(
      children: [
        HomeHero(
          title: '${greeting()}${name == null ? '' : ', $name'}',
          subtitle: 'Open a subject to take attendance, review requests and publish results.',
          actions: [
            FilledButton.icon(
              onPressed: preparing ? null : create,
              icon: const Icon(Icons.add),
              label: Text(preparing ? 'Loading…' : 'Add subject'),
            ),
            OutlinedButton.icon(
              onPressed: refreshAll,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const AttentionCard(),
        const SectionTitle('Your subjects'),
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
        const SizedBox(height: 28),
        TeacherDashboard(
          key: ValueKey(dashboardTick),
          api: api,
          institute: institute,
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
  late Future<Offering> record;
  late final PagedController<Enrollment> requests, students;
  late final PagedController<BiometricAttempt> faces;
  int tab = 3;
  bool loadingCode = false;
  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    record = api.offering(institute, widget.id);
    requests = PagedController(
      (cursor) => api.roster(institute, widget.id, 'requested', cursor: cursor),
    );
    students = PagedController(
      (cursor) => api.roster(institute, widget.id, 'active', cursor: cursor),
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
    requests.load();
    students.load();
    faces.load();
    watchLifecycle();
  }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() => record = api.offering(institute, widget.id));
    await Future.wait([requests.load(), students.load(), faces.load()]);
  }

  @override
  void refreshOnResume() {
    refresh();
  }

  @override
  void dispose() {
    unwatchLifecycle();
    requests.dispose();
    students.dispose();
    faces.dispose();
    super.dispose();
  }

  Future<void> review(Enrollment entry, bool approve) async {
    final reason = TextEditingController();
    await showDialog<bool>(
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
    if (mounted) await refresh();
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
  Widget build(BuildContext context) => FutureBuilder<Offering>(
    future: record,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return ContentPage(
          children: [ErrorView(snapshot.error!, retry: refresh)],
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final o = snapshot.data!;
      return ContentPage(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => goBack(context, '/classes'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('All subjects'),
            ),
          ),
          PageHeader(
            compact: true,
            title: o.title,
            subtitle: '${o.subtitle} · ${o.termCode}',
            eyebrow: 'FACULTY WORKSPACE',
            icon: Icons.space_dashboard_outlined,
            action: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                FilledButton.icon(
                  onPressed: loadingCode ? null : code,
                  icon: const Icon(Icons.key_outlined),
                  label: const Text('Join code'),
                ),
              ],
            ),
          ),
          Panel(
            padding: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Sessions'),
                      selected: tab == 3,
                      onSelected: (_) => setState(() => tab = 3),
                    ),
                    ChoiceChip(
                      label: const Text('Join requests'),
                      selected: tab == 0,
                      onSelected: (_) => setState(() => tab = 0),
                    ),
                    ChoiceChip(
                      label: const Text('Face reviews'),
                      selected: tab == 2,
                      onSelected: (_) => setState(() => tab = 2),
                    ),
                    ChoiceChip(
                      label: const Text('Students'),
                      selected: tab == 1,
                      onSelected: (_) => setState(() => tab = 1),
                    ),
                    ChoiceChip(
                      label: const Text('Attendance queries'),
                      selected: tab == 4,
                      onSelected: (_) => setState(() => tab = 4),
                    ),
                    ChoiceChip(
                      label: const Text('Overview'),
                      selected: tab == 5,
                      onSelected: (_) => setState(() => tab = 5),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  tab == 3
                      ? 'Create a session, capture the classroom and review attendance before publishing.'
                      : tab == 2
                      ? 'Review each recording before activating face enrolment. Subject membership is approved separately.'
                      : tab == 4
                      ? 'Review questions about published Absent results. Accepted queries create a corrected publication and report.'
                      : tab == 5
                      ? 'Cumulative attendance across every published class for this subject.'
                      : tab == 0
                      ? 'Approve requests only after confirming the student belongs in this subject.'
                      : 'These approved students can be included when a classroom session opens.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (tab == 3)
            TeacherSessions(
              api: api,
              institute: institute,
              offering: widget.id,
              publishableKey: ref.read(servicesProvider).config.publishableKey,
            )
          else if (tab == 2)
            BiometricReviews(controller: faces, api: api, institute: institute)
          else if (tab == 4)
            TeacherDisputes(api: api, institute: institute, offering: widget.id)
          else if (tab == 5)
            AttendanceOverview(
              api: api,
              institute: institute,
              offering: widget.id,
            )
          else
            PagedList(
              controller: tab == 0 ? requests : students,
              emptyTitle: tab == 0
                  ? 'No pending requests'
                  : 'No approved students',
              emptyMessage: tab == 0
                  ? 'New student requests will appear here.'
                  : 'Approve subject requests to build your roster.',
              item: (Enrollment e) => Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name ?? 'Student',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('Enrolment number: ${e.number ?? ''}'),
                    const SizedBox(height: 16),
                    if (tab == 0)
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: () => review(e, true),
                            child: const Text('Approve'),
                          ),
                          OutlinedButton(
                            onPressed: () => review(e, false),
                            child: const Text('Decline'),
                          ),
                        ],
                      )
                    else
                      const StatusBadge('active'),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
