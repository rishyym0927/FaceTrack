import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'admin/admin_forms.dart';
part 'admin/admin_academic_editor.dart';
part 'admin/admin_tour.dart';
part 'admin/admin_widgets.dart';

/// Administrative provisioning: academic structure, identities and roles.
/// Every write calls a /v1/admin/* endpoint backed by an app.admin_* database
/// function that re-checks the caller is an active admin, so this screen is a
/// convenience over a server that enforces the rules itself.
///
/// The console opens on an Overview whose setup timeline always names the next
/// step; forms open in dialogs, and a restartable guided tour explains it all.
class TeacherAdmin extends ConsumerStatefulWidget {
  const TeacherAdmin({super.key});
  @override
  ConsumerState<TeacherAdmin> createState() => _TeacherAdminState();
}

enum _Section { overview, academics, people, access }

/// Forms that can be opened from anywhere on the console.
enum _Target {
  term,
  subject,
  section,
  allocation,
  faculty,
  student,
  assign,
  role,
}

const _green = AppTone.success;
const _amber = AppTone.warning;
const _grey = AppTone.neutral;

/// Key in SharedPreferences: the tour has been shown to this account.
String adminTourSeenKey(String userId) => 'facetrack.admin.tour.v1.$userId';

class _Step {
  const _Step(this.title, this.help, this.count, this.section, this.target);
  final String title, help;

  /// Items created so far, or null when the API cannot tell (assignments).
  final int? count;
  final _Section section;
  final _Target target;
  bool get done => (count ?? 0) > 0;
}

class _TeacherAdminState extends ConsumerState<TeacherAdmin> {
  late final ApiClient api;
  late final String institute;
  _Section section = _Section.overview;
  bool peopleStudents = false;
  bool manageAcademic = false;
  bool loading = true;
  Object? loadError;
  String? studentsError;

  /// Label (or number) of the record just created, highlighted until the next
  /// section change.
  String? fresh;

  List<Academic> terms = [], courses = [], groups = [];
  List<Offering> offerings = [];
  List<Json> teachers = [], students = [];

  final _k = {
    for (final n in [
      'tour',
      'progress',
      'next',
      'timeline',
      'nav',
      'academic',
      'addTerm',
      'people',
      'access',
      'stats',
      'quick',
    ])
      n: GlobalKey(debugLabel: 'admin-$n'),
  };
  late final _TourController tour = _TourController(
    steps: () => _tourSteps,
    prepare: _prepareStep,
    onEnd: _markTourSeen,
  );

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    _reload();
  }

  @override
  void dispose() {
    tour.dispose();
    super.dispose();
  }

  Future<List<Offering>> _allOfferings() async {
    final all = <Offering>[];
    String? cursor;
    var pages = 0;
    do {
      final page = await api.offerings(institute, cursor: cursor);
      all.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null && ++pages < 10);
    return all;
  }

  int _reloadGeneration = 0;

  int _directoryGeneration = 0;
  bool _directoriesLoaded = false;
  String? teachersError;

  Future<void> _reload() async {
    final generation = ++_reloadGeneration;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final lists = await Future.wait<Object>([
        api.academics(institute, 'terms'),
        api.academics(institute, 'courses'),
        api.academics(institute, 'class-groups'),
        _allOfferings(),
      ]);
      if (!mounted || generation != _reloadGeneration) return;
      setState(() {
        terms = lists[0] as List<Academic>;
        courses = lists[1] as List<Academic>;
        groups = lists[2] as List<Academic>;
        offerings = lists[3] as List<Offering>;
        loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _reloadGeneration) return;
      setState(() {
        loading = false;
        loadError = e;
      });
    }
    if (mounted && generation == _reloadGeneration && section != _Section.academics) {
      await _reloadDirectories();
    }
  }

  Future<void> _reloadDirectories() async {
    final generation = ++_directoryGeneration;
    await Future.wait([
      for (final kind in ['teachers', 'students'])
        () async {
          try {
            final rows = await fetchAllPages(api, '/v1/admin/$kind', institute, maxPages: 25);
            if (!mounted || generation != _directoryGeneration) return;
            setState(() {
              if (kind == 'teachers') {
                teachers = rows;
                teachersError = null;
              } else {
                students = rows;
                studentsError = null;
              }
            });
          } catch (e) {
            if (!mounted || generation != _directoryGeneration) return;
            final message = e is AppFailure ? e.message : 'Could not load $kind.';
            setState(() {
              if (kind == 'teachers') {
                teachers = [];
                teachersError = message;
              } else {
                students = [];
                studentsError = message;
              }
            });
          }
        }(),
    ]);
    if (mounted && generation == _directoryGeneration) {
      setState(() => _directoriesLoaded = true);
    }
  }

  /// One idempotency key per endpoint: a retry of the same form after a lost
  /// response reuses it (no duplicate record); renewed after success.
  final _mutations = <String, Mutation>{};

  Future<Json> _post(String path, Json body) async {
    final mutation = _mutations.putIfAbsent(path, Mutation.new);
    final result = await api.send(
      'POST',
      path,
      institute: institute,
      body: body,
      mutation: mutation,
    );
    mutation.reset();
    return result;
  }

  /// Runs [action]; on success confirms it, highlights [created] and reloads.
  /// Returns null on success, otherwise the message for the open form.
  Future<String?> _run(
    String success,
    Future<void> Function() action, {
    String? created,
  }) async {
    try {
      await action();
      if (!mounted) return null;
      showMessage(context, success);
      fresh = created;
      await _reload();
      return null;
    } catch (e) {
      final message = e is AppFailure
          ? e.message
          : 'Action failed. Please retry.';
      if (mounted) showMessage(context, message);
      return message;
    }
  }

  /// Creates a login for an existing faculty/student record using its own email.
  Future<String?> _addLogin(String kind, Json person, String password) => _run(
    'Login created for ${person['official_name']}. Share the password privately.',
    () =>
        _post('/v1/admin/$kind/${person['id']}/login', {'password': password}),
  );

  static int _linked(List<Json> people) =>
      people.where((p) => p['auth_user_id'] != null).length;

  List<_Step> get _steps => [
    _Step(
      'Create the semester term',
      'The academic period, e.g. 2026-ODD for Odd Semester 2026.',
      terms.length,
      _Section.academics,
      _Target.term,
    ),
    _Step(
      'Add subjects',
      'Every subject on the timetable with its code, e.g. BCS 201 · Design & Analysis of Algorithm.',
      courses.length,
      _Section.academics,
      _Target.subject,
    ),
    _Step(
      'Add sections',
      'Branch and semester, e.g. CSE · 3rd Semester.',
      groups.length,
      _Section.academics,
      _Target.section,
    ),
    _Step(
      'Allocate subjects to sections',
      'Links a subject to the section that studies it. Faculty and students work inside these.',
      offerings.length,
      _Section.academics,
      _Target.allocation,
    ),
    _Step(
      'Add faculty',
      'Faculty records from institute records, with a login account so they can sign in.',
      teachers.length,
      _Section.people,
      _Target.faculty,
    ),
    _Step(
      'Assign faculty to subjects',
      'Gives a faculty member access to a subject and its attendance. Do this after steps 4 and 5.',
      null,
      _Section.access,
      _Target.assign,
    ),
    _Step(
      'Add students',
      'Student records. Students then sign up and link their enrolment number.',
      students.length,
      _Section.people,
      _Target.student,
    ),
  ];

  // --- Navigation and forms ----------------------------------------------------
  void _goSection(_Section s) {
    setState(() {
      section = s;
      fresh = null;
    });
    if (s != _Section.academics && !_directoriesLoaded) _reloadDirectories();
  }

  Widget _formFor(_Target t) => switch (t) {
    _Target.term => _TermForm(
      onSubmit: (b) => _run(
        'Semester term created.',
        () => _post('/v1/admin/terms', b),
        created: b['code'] as String?,
      ),
    ),
    _Target.subject => _CourseForm(
      onSubmit: (b) => _run(
        'Subject created.',
        () => _post('/v1/admin/courses', b),
        created: b['code'] as String?,
      ),
    ),
    _Target.section => _GroupForm(
      terms: terms,
      onSubmit: (b) => _run(
        'Section created.',
        () => _post('/v1/admin/class-groups', b),
        created: b['branch'] as String?,
      ),
    ),
    _Target.allocation => _OfferingForm(
      courses: courses,
      groups: groups,
      onSubmit: (b) => _run(
        'Subject allocated to the section.',
        () => _post('/v1/admin/offerings', b),
        created: b['title'] as String?,
      ),
    ),
    _Target.faculty => _IdentityForm(
      title: 'Add faculty',
      onSubmit: (b) => _run(
        b['create_login'] == true
            ? 'Faculty created with a login account.'
            : 'Faculty record created.',
        () => _post('/v1/admin/teachers', b),
        created: b['official_email'] as String?,
      ),
    ),
    _Target.student => _IdentityForm(
      title: 'Add student',
      numberLabel: 'Enrolment number',
      numberHelp: 'Exactly as on institute records; students use it to link their account.',
      onSubmit: (b) => _run(
        b['create_login'] == true
            ? 'Student created with a login account.'
            : 'Student record created.',
        () => _post('/v1/admin/students', b),
        created: b['number'] as String?,
      ),
    ),
    _Target.assign => _AssignForm(
      offerings: offerings,
      teachers: teachers,
      onSubmit: (b) => _run(
        'Faculty assigned to the subject.',
        () => _post('/v1/admin/assignments', b),
      ),
    ),
    _Target.role => _RoleForm(
      teachers: teachers,
      students: students,
      onSubmit: (b) =>
          _run('Role updated.', () => _post('/v1/admin/memberships', b)),
    ),
  };

  Future<void> _open(_Target t) {
    if (t == _Target.faculty || t == _Target.student) {
      peopleStudents = t == _Target.student;
    }
    return _showFormDialog(context, _formFor(t));
  }

  // --- Tour ------------------------------------------------------------------------
  List<_TourStep> get _tourSteps => [
    const _TourStep(
      title: 'Welcome to the Admin console',
      body:
          'This short tour shows where everything is and how to set up your institute. '
          'It takes about a minute. Use Next, or the arrow keys.',
      section: _Section.overview,
      icon: Icons.waving_hand_outlined,
    ),
    _TourStep(
      title: 'Your setup progress',
      body:
          'This ring fills as you complete the setup steps. When it is full, faculty can '
          'take attendance in every subject.',
      section: _Section.overview,
      target: _k['progress'],
      icon: Icons.donut_large,
    ),
    _TourStep(
      title: 'Always know the next step',
      body:
          'This card names the next thing to do. "Do it now" opens the right form, '
          'so you never have to search for it.',
      section: _Section.overview,
      target: _k['next'],
      icon: Icons.flag_outlined,
    ),
    _TourStep(
      title: 'The setup timeline',
      body:
          'Seven steps in order: term, subjects, sections, allocations, faculty, '
          'assignments and students. Each shows how many you have created.',
      section: _Section.overview,
      target: _k['timeline'],
      icon: Icons.timeline,
    ),
    _TourStep(
      title: 'Move between areas',
      body:
          'Overview for progress and statistics, Academic setup for the structure, '
          'People for faculty and students, and Access for assignments and roles.',
      section: _Section.overview,
      target: _k['nav'],
      icon: Icons.menu_open,
    ),
    _TourStep(
      title: 'Academic setup',
      body:
          'Four cards, filled in order. A card stays locked until what it needs exists, '
          'for example sections need a semester term first.',
      section: _Section.academics,
      target: _k['academic'],
      icon: Icons.account_tree_outlined,
    ),
    _TourStep(
      title: 'Try adding something',
      body:
          'Every Add button opens a short form with examples. Nothing is saved until you '
          'press Create, and you can cancel at any time.',
      section: _Section.academics,
      target: _k['addTerm'],
      icon: Icons.add_circle_outline,
    ),
    _TourStep(
      title: 'Faculty and students',
      body:
          'Search the directories, filter people who still need a login, and use '
          '"Create login" to give them a temporary password. Share it privately.',
      section: _Section.people,
      target: _k['people'],
      icon: Icons.people_outline,
    ),
    _TourStep(
      title: 'Access and roles',
      body:
          'Assign each subject to the faculty member who teaches it, make someone an Admin, '
          'or suspend access. People see changes after they refresh.',
      section: _Section.access,
      target: _k['access'],
      icon: Icons.key_outlined,
    ),
    _TourStep(
      title: 'Statistics at a glance',
      body:
          'Live counts and charts show what exists and who still needs a login. '
          'Institute-wide attendance appears below once subjects have classes.',
      section: _Section.overview,
      target: _k['stats'],
      icon: Icons.insights_outlined,
    ),
    _TourStep(
      title: 'You are ready',
      body:
          'Start with the next step on the Overview. You can replay this tour any time '
          'with "Take the tour". Tap an ⓘ for help on any term.',
      section: _Section.overview,
      target: _k['tour'],
      icon: Icons.check_circle_outline,
    ),
  ];

  Future<void> _prepareStep(_TourStep step) async {
    if (!mounted) return;
    if (section != step.section) _goSection(step.section);
    await WidgetsBinding.instance.endOfFrame;
    final ctx = step.target?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: .2,
        duration: MediaQuery.disableAnimationsOf(ctx)
            ? Duration.zero
            : const Duration(milliseconds: 300),
      );
    }
  }

  void _startTour() => tour.start(context);

  String? get _userId => ref.read(authProvider).account?.userId;

  Future<void> _markTourSeen() async {
    final user = _userId;
    if (user == null) return;
    try {
      await (await SharedPreferences.getInstance()).setBool(
        adminTourSeenKey(user),
        true,
      );
    } catch (_) {
      // A convenience only; the tour can always be restarted.
    }
  }

  // --- Page ------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (loading && terms.isEmpty && teachers.isEmpty) {
      body = Semantics(
        label: 'Loading the admin console',
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SkeletonStatGrid(),
            SizedBox(height: AppSpace.xl),
            SkeletonPanel(),
          ],
        ),
      );
    } else if (loadError != null) {
      body = ErrorView(loadError!, retry: _reload);
    } else {
      body = LayoutBuilder(
        builder: (context, c) {
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (section) {
              _Section.overview => _overview(),
              _Section.academics => _academics(),
              _Section.people => _people(),
              _Section.access => _access(),
            },
          );
          if (c.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 232,
                  child: KeyedSubtree(key: _k['nav'], child: _sideNav()),
                ),
                const SizedBox(width: AppSpace.xl),
                Expanded(child: content),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KeyedSubtree(key: _k['nav'], child: _topNav()),
              const SizedBox(height: AppSpace.lg),
              content,
            ],
          );
        },
      );
    }
    return ContentPage(
      onRefresh: _reload,
      children: [_hero(), const SizedBox(height: AppSpace.xl), body],
    );
  }

  Widget _hero() {
    final tracked = _steps.where((s) => s.count != null).toList();
    final done = tracked.where((s) => s.done).length;
    final name = ref.watch(authProvider).instituteName;
    final phone = MediaQuery.sizeOf(context).width < 600;
    final ringSize = phone ? 68.0 : 104.0;
    final ring = Semantics(
      label: 'Setup progress: $done of ${tracked.length} steps done',
      child: ExcludeSemantics(
        child: SizedBox(
          key: _k['progress'],
          width: ringSize,
          height: ringSize,
          child: Stack(
            fit: StackFit.expand,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: tracked.isEmpty ? 0 : done / tracked.length),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => CircularProgressIndicator(
                  value: v,
                  strokeWidth: phone ? 6 : 8,
                  strokeCap: StrokeCap.round,
                  backgroundColor: const Color(0x33ffffff),
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(phone ? 12 : 16),
                child: FittedBox(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$done/${tracked.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Text(
                        'setup steps',
                        style: TextStyle(color: Brand.mint, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    const title = Text(
      'Administration',
      style: TextStyle(
        color: Colors.white,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -.5,
      ),
    );
    final subtitle = Text(
      '${name.isEmpty ? 'Your institute' : name}: set up subjects and sections, '
      'add people and control who can do what.',
      style: const TextStyle(color: Brand.mint, height: 1.45),
    );
    final actions = Theme(
      data: Theme.of(context).copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Brand.green,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Color(0x66ffffff)),
          ),
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            key: _k['tour'],
            onPressed: _startTour,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Take the tour'),
          ),
          OutlinedButton.icon(
            onPressed: loading ? null : _reload,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
    return Container(
      padding: EdgeInsets.all(phone ? AppSpace.lg + 4 : 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        gradient: Brand.gradient,
      ),
      child: phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: title),
                    const SizedBox(width: AppSpace.md),
                    ring,
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                subtitle,
                const SizedBox(height: AppSpace.lg),
                actions,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: AppSpace.xs + 2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: subtitle,
                      ),
                      const SizedBox(height: AppSpace.lg),
                      actions,
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.xl),
                ring,
              ],
            ),
    );
  }

  ({IconData icon, String title, String? badge}) _navInfo(_Section s) {
    final steps = _steps.where((x) => x.section == s && x.count != null);
    final complete = steps.isNotEmpty && steps.every((x) => x.done);
    return switch (s) {
      _Section.overview => (
        icon: Icons.dashboard_outlined,
        title: 'Overview',
        badge: null,
      ),
      _Section.academics => (
        icon: Icons.account_tree_outlined,
        title: 'Academic setup',
        badge: complete ? 'done' : null,
      ),
      _Section.people => (
        icon: Icons.people_outline,
        title: 'People',
        badge: complete ? 'done' : '${teachers.length + students.length}',
      ),
      _Section.access => (
        icon: Icons.key_outlined,
        title: 'Access',
        badge: null,
      ),
    };
  }

  Widget _sideNav() {
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      padding: AppSpace.sm,
      child: Column(
        children: [
          for (final s in _Section.values)
            Builder(
              builder: (context) {
                final info = _navInfo(s), on = section == s;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Material(
                    color: on
                        ? scheme.primary.withValues(alpha: .10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      onTap: () => _goSection(s),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 13,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              info.icon,
                              size: 22,
                              color: on
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                info.title,
                                style: TextStyle(
                                  fontWeight: on
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: on
                                      ? scheme.primary
                                      : scheme.onSurface,
                                ),
                              ),
                            ),
                            if (info.badge == 'done')
                              const Icon(
                                Icons.check_circle,
                                color: AppTone.success,
                                size: 18,
                              )
                            else if (info.badge != null)
                              Badge(
                                label: Text(info.badge!),
                                backgroundColor: scheme.primary,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  /// Phones: the four areas as a row of pills that scrolls sideways if needed.
  Widget _topNav() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final s in _Section.values)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.sm),
            child: ChoiceChip(
              showCheckmark: false,
              avatar: Icon(
                _navInfo(s).badge == 'done'
                    ? Icons.check_circle
                    : _navInfo(s).icon,
                size: 18,
                color: section == s
                    ? Theme.of(context).colorScheme.primary
                    : _navInfo(s).badge == 'done'
                    ? AppTone.success
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              label: Text(_navInfo(s).title),
              selected: section == s,
              onSelected: (_) => _goSection(s),
            ),
          ),
      ],
    ),
  );

  // --- Overview ----------------------------------------------------------------------
  List<Widget> _overview() {
    final steps = _steps;
    final tracked = steps.where((s) => s.count != null).toList();
    final done = tracked.where((s) => s.done).length;
    final next = steps.where((s) => s.count != null && !s.done).firstOrNull;
    return [
      KeyedSubtree(
        key: _k['next'],
        child: next == null
            ? _NextCard(
                icon: Icons.celebration_outlined,
                eyebrow: 'SETUP COMPLETE',
                title: 'Your institute is ready',
                body:
                    'Faculty can take attendance. Keep people and access up to date, '
                    'and check that every subject has its faculty in Access.',
                action: OutlinedButton(
                  onPressed: () => _goSection(_Section.access),
                  child: const Text('Review access'),
                ),
              )
            : _NextCard(
                icon: Icons.flag_outlined,
                eyebrow:
                    'NEXT STEP · ${steps.indexOf(next) + 1} OF ${steps.length}',
                title: 'Next: ${next.title.toLowerCase()}.',
                body: next.help,
                action: FilledButton.icon(
                  onPressed: () => _open(next.target),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Do it now'),
                ),
              ),
      ),
      const SizedBox(height: 20),
      Panel(
        key: _k['timeline'],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Heading(
              'Setup checklist',
              subtitle:
                  '$done of ${tracked.length} setup steps done. Each step only needs '
                  'doing once per semester.',
              tip: const _InfoTip(
                'Setup checklist',
                'Work from top to bottom. Steps 1–4 build the academic structure, steps 5 and 7 '
                    'add people, and step 6 gives faculty their subjects. Nothing here deletes data.',
              ),
            ),
            TrackBar(
              value: tracked.isEmpty ? 0 : done / tracked.length,
              color: done == tracked.length ? _green : _amber,
              height: 8,
            ),
            const SizedBox(height: 12),
            for (final (i, s) in steps.indexed)
              _timelineRow(
                i + 1,
                s,
                last: i == steps.length - 1,
                isNext: s == next,
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Panel(
        key: _k['quick'],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Heading('Quick actions'),
            StatGrid(
              minTileWidth: 200,
              children: [
                _quick(
                  Icons.badge_outlined,
                  'Add faculty',
                  'With a login account',
                  () => _open(_Target.faculty),
                ),
                _quick(
                  Icons.school_outlined,
                  'Add student',
                  'Enrolment number and email',
                  () => _open(_Target.student),
                ),
                _quick(
                  Icons.link_outlined,
                  'Allocate subject',
                  'Subject to a section',
                  () => _open(_Target.allocation),
                ),
                _quick(
                  Icons.assignment_ind_outlined,
                  'Assign faculty',
                  'Faculty to a subject',
                  () => _open(_Target.assign),
                ),
                _quick(
                  Icons.vpn_key_outlined,
                  'Create logins',
                  'For people without one',
                  () {
                    peopleStudents = _linked(teachers) == teachers.length;
                    _goSection(_Section.people);
                  },
                ),
                _quick(
                  Icons.admin_panel_settings_outlined,
                  'Grant a role',
                  'Faculty, Admin or suspend',
                  () => _open(_Target.role),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      KeyedSubtree(
        key: _k['stats'],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Heading(
              'Institute at a glance',
              tip: const _InfoTip(
                'What these numbers mean',
                'Semester terms, subjects and sections make up the academic structure. An '
                    'allocation is one subject taught to one section. "With login" counts people '
                    'who can sign in.',
              ),
            ),
            StatGrid(
              minTileWidth: 150,
              children: [
                StatTile(
                  label: 'Semester terms',
                  value: terms.length,
                  icon: Icons.date_range_outlined,
                ),
                StatTile(
                  label: 'Subjects',
                  value: courses.length,
                  icon: Icons.menu_book_outlined,
                ),
                StatTile(
                  label: 'Sections',
                  value: groups.length,
                  icon: Icons.groups_2_outlined,
                ),
                StatTile(
                  label: 'Allocations',
                  value: offerings.length,
                  icon: Icons.link_outlined,
                ),
                StatTile(
                  label: 'Faculty',
                  value: teachers.length,
                  icon: Icons.badge_outlined,
                  caption: teachersError ?? (_directoriesLoaded ? '${_linked(teachers)} with login' : 'Loading'),
                ),
                StatTile(
                  label: 'Students',
                  value: students.length,
                  icon: Icons.school_outlined,
                  caption: studentsError ?? (_directoriesLoaded ? '${_linked(students)} with login' : 'Loading'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Panel(
              child: LayoutBuilder(
                builder: (context, c) {
                  final charts = [_accountsChart(), _bySemesterChart()];
                  if (c.maxWidth >= 700) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: charts[0]),
                        const SizedBox(width: 32),
                        Expanded(child: charts[1]),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      charts[0],
                      const SizedBox(height: 24),
                      charts[1],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _quick(IconData icon, String title, String sub, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, color: scheme.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      sub,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timelineRow(
    int n,
    _Step s, {
    required bool last,
    required bool isNext,
  }) {
    final theme = Theme.of(context);
    final untracked = s.count == null;
    final (label, color) = untracked
        ? ('Check each subject has its faculty', _grey)
        : s.done
        ? ('${s.count} created', _green)
        : isNext
        ? ('Up next', _amber)
        : ('Not started', _grey);
    final action = TextButton(
      onPressed: () => untracked ? _goSection(s.section) : _open(s.target),
      child: Text(untracked ? 'Open' : (s.done ? 'Add more' : 'Start')),
    );
    // Wide rows keep the status and action on the right of the text.
    return LayoutBuilder(
      builder: (context, c) {
        final inline =
            c.maxWidth >= 640 &&
            MediaQuery.textScalerOf(context).scale(1) <= 1.3;
        return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                const SizedBox(height: 10),
                CircleAvatar(
                  radius: 14,
                  backgroundColor: s.done
                      ? _green
                      : isNext
                      ? _amber
                      : theme.colorScheme.primary.withValues(alpha: .10),
                  child: s.done
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text(
                          '$n',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isNext
                                ? Colors.white
                                : theme.colorScheme.primary,
                          ),
                        ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.only(top: 4),
                      color: s.done
                          ? _green.withValues(alpha: .5)
                          : theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.sm,
                ),
                decoration: BoxDecoration(
                  color: isNext
                      ? theme.colorScheme.primary.withValues(alpha: .05)
                      : null,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: isNext
                      ? Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: .25,
                          ),
                        )
                      : null,
                ),
                child: Builder(
                  builder: (context) {
                    final text = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.help,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    );
                    if (inline) {
                      return Row(
                        children: [
                          Expanded(child: text),
                          const SizedBox(width: AppSpace.md),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: TonePill(label, tone: color),
                          ),
                          const SizedBox(width: AppSpace.xs),
                          SizedBox(width: 84, child: action),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        text,
                        const SizedBox(height: AppSpace.sm),
                        Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [TonePill(label, tone: color), action],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
      },
    );
  }

  Widget _chartTitle(String title, String help) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 2),
      Text(
        help,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 10),
    ],
  );

  Widget _accountsChart() {
    final fl = _linked(teachers), sl = _linked(students);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartTitle(
          'Login accounts',
          'People who can sign in, and who still need an account',
        ),
        BarDistribution(
          labelWidth: 132,
          bars: [
            BarDatum('Faculty with login', fl, _green),
            BarDatum('Faculty without', teachers.length - fl, _amber),
            BarDatum('Students with login', sl, _green),
            BarDatum('Students without', students.length - sl, _amber),
          ],
        ),
      ],
    );
  }

  Widget _bySemesterChart() {
    final sections = <int, int>{}, allocated = <int, int>{};
    for (final g in groups) {
      if (g.semester != null) {
        sections[g.semester!] = (sections[g.semester!] ?? 0) + 1;
      }
    }
    for (final o in offerings) {
      allocated[o.semester] = (allocated[o.semester] ?? 0) + 1;
    }
    final semesters = {...sections.keys, ...allocated.keys}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartTitle(
          'By semester',
          'Sections and subject allocations in each semester',
        ),
        if (semesters.isEmpty)
          const Text('Add sections to see them by semester.')
        else
          BarDistribution(
            labelWidth: 132,
            bars: [
              for (final s in semesters) ...[
                BarDatum(
                  '${semesterLabel(s)} sections',
                  sections[s] ?? 0,
                  const Color(0xff146653),
                ),
                BarDatum(
                  '${semesterLabel(s)} subjects',
                  allocated[s] ?? 0,
                  const Color(0xff3f9e6b),
                ),
              ],
            ],
          ),
      ],
    );
  }

  // --- Academic setup --------------------------------------------------------------
  Future<void> _editAcademic(_AcademicEntry row) async {
    final version = row.version;
    if (version == null) {
      showMessage(context, 'Reload academic records before editing.');
      return;
    }
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _AcademicEditor(
        row: row,
        save: (fields, mutation) async {
          await api.send(
            'PATCH', '/v1/admin/${row.kind}/${row.id}',
            institute: institute,
            body: fields, mutation: mutation, version: version,
          );
        },
      ),
    );
    if (!mounted || changed == null) return;
    try {
      await ApiClient.freshReads(() async {
        final records = row.kind == 'offerings'
            ? null
            : await api.academics(institute, row.kind);
        final allocations = await _allOfferings();
        if (!mounted) return;
        setState(() {
          switch (row.kind) {
            case 'terms': terms = records!;
            case 'courses': courses = records!;
            case 'class-groups': groups = records!;
          }
          offerings = allocations;
        });
      });
      if (mounted && changed) showMessage(context, 'Academic record updated.');
    } catch (error) {
      if (mounted) {
        showMessage(context, error is AppFailure
            ? error.message : 'Could not refresh academic records.');
      }
    }
  }

  List<Widget> _academics() {
    final cards = [
      _SetupCard(
        number: 1,
        icon: Icons.date_range_outlined,
        title: 'Semester terms',
        about: 'The teaching period, created once each semester.',
        tip: const _InfoTip(
          'Semester term',
          'A semester term is the period classes run in, such as 2026-ODD (Odd Semester 2026). '
              'Create it first: sections belong to a term.',
        ),
        items: [for (final t in terms) t.label],
        fresh: fresh,
        addLabel: 'Add term',
        addKey: _k['addTerm'],
        onAdd: () => _open(_Target.term),
      ),
      _SetupCard(
        number: 2,
        icon: Icons.menu_book_outlined,
        title: 'Subjects',
        about: 'Every subject on the timetable, with its code.',
        tip: const _InfoTip(
          'Subject',
          'A subject is a course with a code, e.g. BCS 201 · Design & Analysis of Algorithm. '
              'Add it once; it can then be taught to several sections.',
        ),
        items: [for (final c in courses) c.label],
        fresh: fresh,
        addLabel: 'Add subject',
        onAdd: () => _open(_Target.subject),
      ),
      _SetupCard(
        number: 3,
        icon: Icons.groups_2_outlined,
        title: 'Sections',
        about: 'A group of students: branch and semester.',
        tip: const _InfoTip(
          'Section',
          'A section is one group of students that attends classes together, e.g. '
              'CSE · 3rd Semester. It belongs to a semester term.',
        ),
        items: [for (final g in groups) _sectionLabel(g)],
        fresh: fresh,
        addLabel: 'Add section',
        blocked: terms.isEmpty ? 'Create a semester term first.' : null,
        onAdd: () => _open(_Target.section),
      ),
      _SetupCard(
        number: 4,
        icon: Icons.link_outlined,
        title: 'Allocations',
        about: 'Which subject each section studies.',
        tip: const _InfoTip(
          'Allocation',
          'An allocation links one subject to one section. Faculty take attendance and students '
              'join inside allocations, so add one for every subject a section studies.',
        ),
        items: [for (final o in offerings) '${o.title} · ${o.subtitle}'],
        fresh: fresh,
        addLabel: 'Allocate subject',
        blocked: courses.isEmpty
            ? 'Add a subject first.'
            : groups.isEmpty
            ? 'Add a section first.'
            : null,
        onAdd: () => _open(_Target.allocation),
      ),
    ];
    return [
      _Heading(
        'Academic setup',
        subtitle:
            'Build the structure in order: term → subjects → sections → allocations. '
            'Use the names and codes from the timetable.',
        trailing: OutlinedButton.icon(
          icon: Icon(manageAcademic ? Icons.expand_less : Icons.edit_outlined),
          label: Text(
            manageAcademic ? 'Hide record editor' : 'Manage academic records',
          ),
          onPressed: () => setState(() => manageAcademic = !manageAcademic),
        ),
      ),
      if (manageAcademic)
        _AcademicManagement(
          terms: terms, courses: courses, groups: groups, offerings: offerings,
          edit: _editAcademic,
        ),
      const SizedBox(height: 16),
      LayoutBuilder(
        key: _k['academic'],
        builder: (context, c) {
          if (c.maxWidth < 640) {
            return Column(
              children: [
                for (final card in cards)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: card,
                  ),
              ],
            );
          }
          return Column(
            children: [
              for (var i = 0; i < cards.length; i += 2)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: cards[i]),
                        const SizedBox(width: 16),
                        Expanded(child: cards[i + 1]),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  // --- People ----------------------------------------------------------------------
  List<Widget> _people() {
    final kind = peopleStudents ? 'students' : 'teachers';
    return [
      _Heading(
        'People',
        subtitle:
            'Faculty and students from institute records, and who can sign in.',
        tip: const _InfoTip(
          'Records and logins',
          'A record holds the official name, number and email. A login lets that person sign '
              'in with the same email. Share temporary passwords privately, never by email or chat. '
              'Students then join subjects with a join code from their faculty.',
        ),
        trailing: FilledButton.icon(
          onPressed: () =>
              _open(peopleStudents ? _Target.student : _Target.faculty),
          icon: const Icon(Icons.person_add_alt_1),
          label: Text(peopleStudents ? 'Add student' : 'Add faculty'),
        ),
      ),
      Panel(
        key: _k['people'],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.badge_outlined),
                    label: Text('Faculty ${teachers.length}'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.school_outlined),
                    label: Text('Students ${students.length}'),
                  ),
                ],
                selected: {peopleStudents},
                onSelectionChanged: (v) =>
                    setState(() => peopleStudents = v.first),
              ),
            ),
            const SizedBox(height: 16),
            if (peopleStudents && studentsError != null)
              _Note('Students could not be loaded: $studentsError')
            else
              _Directory(
                key: ValueKey(kind),
                title: peopleStudents
                    ? 'Student directory'
                    : 'Faculty directory',
                people: peopleStudents ? students : teachers,
                numberKey: peopleStudents ? 'enrollment_number' : null,
                fresh: fresh,
                onCreateLogin: (p, password) => _addLogin(kind, p, password),
              ),
          ],
        ),
      ),
    ];
  }

  // --- Access ----------------------------------------------------------------------
  List<Widget> _access() {
    Widget card({
      required IconData icon,
      required String title,
      required String about,
      required _InfoTip tip,
      required List<String> points,
      required Widget action,
    }) {
      final scheme = Theme.of(context).colorScheme;
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                tip,
              ],
            ),
            const SizedBox(height: 8),
            Text(about, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            for (final p in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check, size: 16, color: _green),
                    const SizedBox(width: 8),
                    Expanded(child: Text(p)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            action,
          ],
        ),
      );
    }

    return [
      const _Heading(
        'Access',
        subtitle: 'Decide who teaches which subject and who can manage the institute.',
      ),
      Column(
        key: _k['access'],
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card(
            icon: Icons.assignment_ind_outlined,
            title: 'Assign faculty to a subject',
            about:
                '${offerings.length} subjects allocated · ${teachers.length} faculty',
            tip: const _InfoTip(
              'Assigning faculty',
              'The assigned faculty member sees the subject, its students and its attendance. '
                  '"Can publish attendance" lets them finalize and publish it. If someone is '
                  'missing from the list, add them in People or give them the Faculty role.',
            ),
            points: const [
              'Do this for every subject after allocating it to a section.',
              'A subject can have more than one faculty member.',
            ],
            action: FilledButton.icon(
              onPressed: offerings.isEmpty || teachers.isEmpty
                  ? null
                  : () => _open(_Target.assign),
              icon: const Icon(Icons.assignment_ind_outlined),
              label: const Text('Assign faculty'),
            ),
          ),
          if (offerings.isEmpty || teachers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _Note(
                offerings.isEmpty
                    ? 'Allocate a subject to a section first (Academic setup).'
                    : 'Add faculty first (People).',
              ),
            ),
          const SizedBox(height: 16),
          card(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Roles and access',
            about: 'Change what an existing login account can do.',
            tip: const _InfoTip(
              'Roles',
              'Student: sees their own attendance. Faculty: takes attendance in assigned subjects. '
                  'Admin: everything on this console. Suspended stops access without deleting '
                  'anything. People see the change after refreshing or signing in again.',
            ),
            points: const [
              'Make someone Faculty or Admin.',
              'Suspend access when someone leaves, and restore it later.',
            ],
            action: FilledButton.icon(
              onPressed: () => _open(_Target.role),
              icon: const Icon(Icons.key_outlined),
              label: const Text('Grant or change a role'),
            ),
          ),
        ],
      ),
    ];
  }
}

class _NextCard extends StatelessWidget {
  const _NextCard({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.action,
  });
  final IconData icon;
  final String eyebrow, title, body;
  final Widget action;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      accent: true,
      child: Wrap(
        spacing: 16,
        runSpacing: 14,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}

/// One academic building block: count, a preview of what exists, and Add —
/// locked with a reason until its prerequisite exists.
class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.number,
    required this.icon,
    required this.title,
    required this.about,
    required this.tip,
    required this.items,
    required this.addLabel,
    required this.onAdd,
    this.fresh,
    this.blocked,
    this.addKey,
  });
  final int number;
  final IconData icon;
  final String title, about, addLabel;
  final _InfoTip tip;
  final List<String> items;
  final VoidCallback onAdd;
  final String? fresh, blocked;
  final Key? addKey;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = items.isNotEmpty;
    return Panel(
      padding: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (done ? _green : scheme.primary).withValues(
                    alpha: .10,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(
                  done ? Icons.check_circle : icon,
                  color: done ? _green : scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STEP $number',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
              tip,
              const SizedBox(width: AppSpace.xs),
              Text(
                '${items.length}',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                  color: done ? _green : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            about,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: AppSpace.md),
          if (items.isEmpty)
            const EmptyState(
              compact: true,
              icon: Icons.inbox_outlined,
              title: 'Nothing added yet',
            )
          else
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: scheme.outline),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (i, label) in items.take(4).indexed)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.md,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: fresh != null && label.contains(fresh!)
                            ? _green.withValues(alpha: .10)
                            : null,
                        border: i == 0
                            ? null
                            : Border(top: BorderSide(color: scheme.outline)),
                      ),
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: AppSpace.md),
          if (blocked != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 16, color: _amber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      blocked!,
                      style: const TextStyle(color: _amber, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                key: addKey,
                onPressed: blocked == null ? onAdd : null,
                icon: const Icon(Icons.add, size: 18),
                label: Text(addLabel),
              ),
              if (items.isNotEmpty)
                TextButton(
                  onPressed: () => _showListDialog(context, title, items),
                  child: Text('View all ${items.length}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
