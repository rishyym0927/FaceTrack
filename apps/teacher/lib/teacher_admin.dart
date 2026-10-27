import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'teacher_dashboard.dart';

/// Administrative provisioning: academic structure, identities and roles.
/// Every write calls a /v1/admin/* endpoint backed by an app.admin_* database
/// function that re-checks the caller is an active admin, so this screen is a
/// convenience over a server that enforces the rules itself.
///
/// The Overview turns the setup order into a checklist with live counts, so an
/// admin always knows the next step; each step jumps to the form that does it.
class TeacherAdmin extends ConsumerStatefulWidget {
  const TeacherAdmin({super.key});
  @override
  ConsumerState<TeacherAdmin> createState() => _TeacherAdminState();
}

enum _Section { overview, academics, people, access }

/// Forms the checklist can jump to.
enum _Target { term, subject, section, allocation, faculty, student, assign, role }

const _green = Color(0xff176451);
const _amber = Color(0xff9a6a00);
const _grey = Color(0xff587067);

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
  bool loading = true;
  String? loadError, studentsError;
  final _keys = {for (final t in _Target.values) t: GlobalKey()};
  final Set<_Target> _opened = {}, _closed = {};

  List<Academic> terms = [], courses = [], groups = [];
  List<Offering> offerings = [];
  List<Json> teachers = [], students = [];

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    _reload();
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

  List<Json> _items(Object? data) => ((data as Map)['items'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  Future<void> _reload() async {
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
        api.send('GET', '/v1/admin/teachers', institute: institute),
      ]);
      List<Json> studentList = [];
      String? studentProblem;
      try {
        studentList = _items(
          await api.send('GET', '/v1/admin/students', institute: institute),
        );
      } catch (e) {
        studentProblem = e is AppFailure ? e.message : 'Could not load students.';
      }
      if (!mounted) return;
      setState(() {
        terms = lists[0] as List<Academic>;
        courses = lists[1] as List<Academic>;
        groups = lists[2] as List<Academic>;
        offerings = lists[3] as List<Offering>;
        teachers = _items(lists[4]);
        students = studentList;
        studentsError = studentProblem;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        loadError = e is AppFailure ? e.message : 'Could not load admin data.';
      });
    }
  }

  Future<Json> _post(String path, Json body) =>
      api.send('POST', path, institute: institute, body: body, mutation: Mutation());

  /// Runs [action], reports success or failure, and reloads lookup data.
  Future<bool> _run(String success, Future<void> Function() action) async {
    try {
      await action();
      if (!mounted) return true;
      showMessage(context, success);
      await _reload();
      return true;
    } catch (e) {
      if (!mounted) return false;
      showMessage(context, e is AppFailure ? e.message : 'Action failed. Please retry.');
      return false;
    }
  }

  /// Creates a login for an existing faculty/student record using its own email.
  Future<bool> _addLogin(String kind, Json person, String password) => _run(
    'Login created for ${person['official_name']}. Share the password privately.',
    () => _post('/v1/admin/$kind/${person['id']}/login', {'password': password}),
  );

  /// Switches section, then brings the requested form into view.
  void _goTo(_Section target, _Target form) {
    setState(() {
      section = target;
      _closed.remove(form);
      _opened.add(form);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[form]!.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .05);
    });
  }

  static int _linked(List<Json> people) =>
      people.where((p) => p['auth_user_id'] != null).length;

  List<_Step> get _steps => [
    _Step('Create the semester term',
        'The academic period, e.g. 2026-ODD for Odd Semester 2026.',
        terms.length, _Section.academics, _Target.term),
    _Step('Add subjects',
        'Every subject on the timetable with its code, e.g. BCS 201 · Design & Analysis of Algorithm.',
        courses.length, _Section.academics, _Target.subject),
    _Step('Add sections',
        'Branch, semester and section, e.g. CSE · 3rd Semester · CSE1.',
        groups.length, _Section.academics, _Target.section),
    _Step('Allocate subjects to sections',
        'Links a subject to the section that studies it. Faculty and students work inside these.',
        offerings.length, _Section.academics, _Target.allocation),
    _Step('Add faculty',
        'Faculty records from institute records, with a login account so they can sign in.',
        teachers.length, _Section.people, _Target.faculty),
    _Step('Assign faculty to subjects',
        'Gives a faculty member access to a subject and its attendance. Do this after steps 4 and 5.',
        null, _Section.access, _Target.assign),
    _Step('Add students',
        'Student records. Students then sign up and link their enrolment number.',
        students.length, _Section.people, _Target.student),
  ];

  bool _sectionDone(_Section s) {
    final tracked = _steps.where((x) => x.section == s && x.count != null);
    return tracked.isNotEmpty && tracked.every((x) => x.done);
  }

  @override
  Widget build(BuildContext context) {
    return ContentPage(
      children: [
        const PageHeader(
          title: 'Administration',
          subtitle:
              'Set up your institute in a few guided steps, then keep people and access up to date.',
          eyebrow: 'ADMIN',
          icon: Icons.admin_panel_settings_outlined,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _Section.values)
              ChoiceChip(
                avatar: Icon(
                  s != _Section.overview && _sectionDone(s)
                      ? Icons.check_circle
                      : switch (s) {
                          _Section.overview => Icons.dashboard_outlined,
                          _Section.academics => Icons.account_tree_outlined,
                          _Section.people => Icons.people_outline,
                          _Section.access => Icons.key_outlined,
                        },
                  size: 18,
                ),
                label: Text(switch (s) {
                  _Section.overview => 'Overview',
                  _Section.academics => '1 · Academic setup',
                  _Section.people => '2 · People',
                  _Section.access => '3 · Access & assignments',
                }),
                selected: section == s,
                onSelected: (_) => setState(() => section = s),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (loading && terms.isEmpty && teachers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (loadError != null)
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(loadError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _reload, child: const Text('Retry')),
              ],
            ),
          )
        else
          ...switch (section) {
            _Section.overview => _overview(),
            _Section.academics => _academics(),
            _Section.people => _people(),
            _Section.access => _access(),
          },
      ],
    );
  }

  // --- Overview --------------------------------------------------------------
  List<Widget> _overview() {
    final steps = _steps;
    final tracked = steps.where((s) => s.count != null).toList();
    final done = tracked.where((s) => s.done).length;
    final next = steps.where((s) => s.count != null && !s.done).firstOrNull;
    final theme = Theme.of(context);
    return [
      const _HowTo(
        title: 'How to use Administration',
        steps: [
          'Work through the setup checklist below from top to bottom. "Start" opens the right form.',
          'Steps 1–4 build the academic structure, steps 5 and 7 add people, and step 6 gives faculty their subjects.',
          'When the checklist is done, faculty can take attendance. This page then shows institute-wide attendance.',
        ],
        tip: 'Every section has its own instructions at the top. Nothing here deletes data.',
      ),
      Panel(
        accent: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Setup checklist', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '$done of ${tracked.length} setup steps done. Work top to bottom; '
              'each step only needs doing once per semester.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            TrackBar(
              value: tracked.isEmpty ? 0 : done / tracked.length,
              color: done == tracked.length ? _green : _amber,
              height: 10,
            ),
            if (next != null) ...[
              const SizedBox(height: 14),
              _Callout(
                icon: Icons.flag_outlined,
                text: 'Next: ${next.title.toLowerCase()}.',
                action: FilledButton(
                  onPressed: () => _goTo(next.section, next.target),
                  child: const Text('Do it now'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            for (final (i, s) in steps.indexed) _stepRow(i + 1, s),
          ],
        ),
      ),
      const SizedBox(height: 20),
      StatGrid(
        minTileWidth: 150,
        children: [
          StatTile(label: 'Semester terms', value: terms.length, icon: Icons.date_range_outlined),
          StatTile(label: 'Subjects', value: courses.length, icon: Icons.menu_book_outlined),
          StatTile(label: 'Sections', value: groups.length, icon: Icons.groups_2_outlined),
          StatTile(
            label: 'Subject allocations',
            value: offerings.length,
            icon: Icons.link_outlined,
          ),
          StatTile(
            label: 'Faculty',
            value: teachers.length,
            icon: Icons.badge_outlined,
            caption: '${_linked(teachers)} with login',
          ),
          StatTile(
            label: 'Students',
            value: students.length,
            icon: Icons.school_outlined,
            caption: studentsError ?? '${_linked(students)} with login',
          ),
        ],
      ),
      const SizedBox(height: 20),
      Panel(
        child: LayoutBuilder(
          builder: (context, c) {
            final charts = [_accountsChart(), _bySemesterChart()];
            if (c.maxWidth >= 760) {
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
              children: [charts[0], const SizedBox(height: 24), charts[1]],
            );
          },
        ),
      ),
      if (offerings.isNotEmpty) ...[
        const SizedBox(height: 20),
        TeacherDashboard(api: api, institute: institute),
      ],
    ];
  }

  Widget _stepRow(int n, _Step s) {
    final theme = Theme.of(context);
    final untracked = s.count == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: s.done
                ? _green
                : theme.colorScheme.primary.withValues(alpha: .10),
            child: s.done
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : Text('$n',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: theme.colorScheme.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(s.help, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      untracked
                          ? 'Check each subject has its faculty'
                          : s.done
                              ? '${s.count} created'
                              : 'Not started',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: untracked ? _grey : (s.done ? _green : _amber),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _goTo(s.section, s.target),
                      child: Text(untracked ? 'Open' : (s.done ? 'Add more' : 'Start')),
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

  Widget _chartTitle(String title, String help) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 2),
      Text(help, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 10),
    ],
  );

  Widget _accountsChart() {
    final fl = _linked(teachers), sl = _linked(students);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartTitle('Login accounts', 'People who can sign in, and who still need an account'),
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
      if (g.semester != null) sections[g.semester!] = (sections[g.semester!] ?? 0) + 1;
    }
    for (final o in offerings) {
      allocated[o.semester] = (allocated[o.semester] ?? 0) + 1;
    }
    final semesters = {...sections.keys, ...allocated.keys}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartTitle('By semester', 'Sections and subject allocations in each semester'),
        if (semesters.isEmpty)
          const Text('Add sections to see them by semester.')
        else
          BarDistribution(
            labelWidth: 132,
            bars: [
              for (final s in semesters) ...[
                BarDatum('${semesterLabel(s)} sections', sections[s] ?? 0,
                    const Color(0xff146653)),
                BarDatum('${semesterLabel(s)} subjects', allocated[s] ?? 0,
                    const Color(0xff3f9e6b)),
              ],
            ],
          ),
      ],
    );
  }

  // --- Task cards ------------------------------------------------------------
  /// Forms start folded into one-line cards; the next unfinished step and the
  /// short Access forms start open, and the admin can open or hide any card.
  bool _isOpen(_Target t) {
    if (_opened.contains(t)) return true;
    if (_closed.contains(t)) return false;
    if (t == _Target.assign || t == _Target.role) return true;
    return _steps.where((s) => s.count != null && !s.done).firstOrNull?.target == t;
  }

  void _toggle(_Target t) => setState(() {
        if (_isOpen(t)) {
          _opened.remove(t);
          _closed.add(t);
        } else {
          _closed.remove(t);
          _opened.add(t);
        }
      });

  Widget _task(
    _Target t, {
    required IconData icon,
    required String title,
    required String summary,
    required Widget form,
    Widget? below,
  }) {
    final open = _isOpen(t);
    return KeyedSubtree(
      key: _keys[t],
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (open) ...[
              form,
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _toggle(t),
                  icon: const Icon(Icons.expand_less),
                  label: const Text('Hide form'),
                ),
              ),
            ] else
              _TaskHeader(icon: icon, title: title, summary: summary, onOpen: () => _toggle(t)),
            ?below,
          ],
        ),
      ),
    );
  }

  static String _count(int n, String noun) => n == 0 ? 'None yet' : '$n $noun created';

  // --- Academics -------------------------------------------------------------
  List<Widget> _academics() => [
        const _HowTo(
          title: 'How to set up the academic structure',
          steps: [
            'Create the semester term once each semester, e.g. 2026-ODD.',
            'Add every subject from the timetable with its code, e.g. BCS 201.',
            'Add each section: branch, semester and section, e.g. CSE · 3rd Semester · CSE1.',
            'Allocate each subject to the section that studies it.',
          ],
          tip: 'Open "Show existing" under a card before adding, so nothing is created twice. '
              'Use the names and codes from the timetable so everyone recognises them.',
        ),
        _task(
          _Target.term,
          icon: Icons.date_range_outlined,
          title: 'Add semester term',
          summary: _count(terms.length, 'semester terms'),
          form: _TermForm(
            onSubmit: (body) => _run('Semester term created.', () => _post('/v1/admin/terms', body)),
          ),
          below: _Existing('semester terms', [for (final t in terms) t.label]),
        ),
        _task(
          _Target.subject,
          icon: Icons.menu_book_outlined,
          title: 'Add subject',
          summary: _count(courses.length, 'subjects'),
          form: _CourseForm(
            onSubmit: (body) => _run('Subject created.', () => _post('/v1/admin/courses', body)),
          ),
          below: _Existing('subjects', [for (final c in courses) c.label]),
        ),
        _task(
          _Target.section,
          icon: Icons.groups_2_outlined,
          title: 'Add section',
          summary: _count(groups.length, 'sections'),
          form: _GroupForm(
            terms: terms,
            onSubmit: (body) => _run('Section created.', () => _post('/v1/admin/class-groups', body)),
          ),
          below: _Existing('sections', [for (final g in groups) g.label]),
        ),
        _task(
          _Target.allocation,
          icon: Icons.link_outlined,
          title: 'Allocate subject to a section',
          summary: _count(offerings.length, 'allocations'),
          form: _OfferingForm(
            courses: courses,
            groups: groups,
            onSubmit: (body) => _run(
              'Subject allocated to the section.',
              () => _post('/v1/admin/offerings', body),
            ),
          ),
          below: _Existing('subject allocations', [for (final o in offerings) '${o.title} · ${o.subtitle}']),
        ),
      ];

  // --- People ----------------------------------------------------------------
  List<Widget> _people() => [
        const _HowTo(
          title: 'How to add people',
          steps: [
            'Add each faculty member with their employee number and official email. Turn on '
                '"Also create a login account" and set a temporary password.',
            'Add students with their enrolment number and official email. Create their login now, '
                'or later with "Create login" in the student directory.',
            'Share each temporary password privately, never by email or chat.',
            'Students then join their subjects with the faculty member\'s join code, and faculty '
                'approve the requests.',
          ],
          tip: 'The official email must be the one the person signs in with. Faculty always need a login.',
        ),
        _task(
          _Target.faculty,
          icon: Icons.badge_outlined,
          title: 'Add faculty',
          summary: '${teachers.length} faculty · ${_linked(teachers)} with login',
          form: _IdentityForm(
            title: 'Add faculty',
            numberLabel: 'Employee number',
            numberHelp: 'Exactly as on institute records.',
            onSubmit: (body) => _run(
              body['create_login'] == true ? 'Faculty created with a login account.' : 'Faculty identity created.',
              () => _post('/v1/admin/teachers', body),
            ),
          ),
          below: _Directory(
            title: 'Faculty directory',
            people: teachers,
            numberKey: 'employee_number',
            onCreateLogin: (p, password) => _addLogin('teachers', p, password),
          ),
        ),
        _task(
          _Target.student,
          icon: Icons.school_outlined,
          title: 'Add student',
          summary: '${students.length} students · ${_linked(students)} with login',
          form: _IdentityForm(
            title: 'Add student',
            numberLabel: 'Enrolment number',
            numberHelp: 'Exactly as on institute records; students use it to link their account.',
            onSubmit: (body) => _run(
              body['create_login'] == true ? 'Student created with a login account.' : 'Student identity created.',
              () => _post('/v1/admin/students', body),
            ),
          ),
          below: studentsError != null
              ? _Note('Students could not be loaded: $studentsError')
              : _Directory(
                  title: 'Student directory',
                  people: students,
                  numberKey: 'enrollment_number',
                  onCreateLogin: (p, password) => _addLogin('students', p, password),
                ),
        ),
      ];

  // --- Access & assignments --------------------------------------------------
  List<Widget> _access() => [
        const _HowTo(
          title: 'How to give access',
          steps: [
            'Assign every subject to the faculty member who teaches it. They then see it, its '
                'students and its attendance.',
            'If someone cannot be chosen as faculty, give them the Faculty role first with '
                '"Grant a role" below.',
            'Use "Grant a role" to make someone an Admin, or set Suspended to stop their access.',
          ],
          tip: 'The person sees the change after refreshing or signing in again.',
        ),
        _task(
          _Target.assign,
          icon: Icons.assignment_ind_outlined,
          title: 'Assign faculty to a subject',
          summary: '${offerings.length} subjects · ${teachers.length} faculty',
          form: _AssignForm(
            offerings: offerings,
            teachers: teachers,
            onSubmit: (body) => _run('Faculty assigned to the subject.', () => _post('/v1/admin/assignments', body)),
          ),
        ),
        _task(
          _Target.role,
          icon: Icons.key_outlined,
          title: 'Grant a role to an existing account',
          summary: 'Faculty, Admin or Student; active or suspended',
          form: _RoleForm(
            teachers: teachers,
            students: students,
            onSubmit: (body) => _run('Role updated.', () => _post('/v1/admin/memberships', body)),
          ),
        ),
      ];
}

/// A folded task: what it is, how much exists, and a button to open its form.
class _TaskHeader extends StatelessWidget {
  const _TaskHeader({required this.icon, required this.title, required this.summary, required this.onOpen});
  final IconData icon;
  final String title, summary;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Panel(
      padding: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: theme.colorScheme.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(summary, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Open form'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Numbered instructions at the top of a section.
class _HowTo extends StatelessWidget {
  const _HowTo({required this.title, required this.steps, this.tip});
  final String title;
  final List<String> steps;
  final String? tip;
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: primary.withValues(alpha: .18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 20, color: primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final (i, step) in steps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 11,
                      backgroundColor: primary,
                      child: Text('${i + 1}',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(step, style: const TextStyle(height: 1.45))),
                  ],
                ),
              ),
            if (tip != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, size: 18, color: primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(tip!,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.45)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

typedef _Submit = Future<bool> Function(Json body);

/// A small stateful wrapper giving each form its own key, busy state and submit button.
class _Form extends StatefulWidget {
  const _Form({
    required this.title,
    required this.action,
    required this.fields,
    required this.collect,
    required this.onSubmit,
    this.help,
  });
  final String title, action;
  final String? help;
  final List<Widget> Function(void Function() rebuild) fields;
  final Json? Function() collect;
  final _Submit onSubmit;
  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  final _key = GlobalKey<FormState>();
  bool busy = false;

  Future<void> _submit() async {
    if (busy || !_key.currentState!.validate()) return;
    final body = widget.collect();
    if (body == null) return;
    setState(() => busy = true);
    final ok = await widget.onSubmit(body);
    if (mounted) setState(() => busy = false);
    if (ok) _key.currentState!.reset();
  }

  @override
  Widget build(BuildContext context) => Panel(
        child: Form(
          key: _key,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
              if (widget.help != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.help!,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 16),
              ...widget.fields(() => setState(() {})),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: busy ? null : _submit,
                  child: Text(busy ? 'Working…' : widget.action),
                ),
              ),
            ],
          ),
        ),
      );
}

Widget _field(
  TextEditingController c,
  String label, {
  String? helper,
  TextInputType? keyboard,
  int max = 150,
  String? Function(String?)? validator,
}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        keyboardType: keyboard,
        maxLength: max,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          counterText: '',
        ),
        validator: validator ?? requiredText,
      ),
    );

String? _date(String? v) {
  if (v == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v.trim())) return 'Use YYYY-MM-DD.';
  return null;
}

String? _email(String? v) {
  if (v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) return 'Enter a valid email.';
  return null;
}

class _TermForm extends StatelessWidget {
  const _TermForm({required this.onSubmit});
  final _Submit onSubmit;
  @override
  Widget build(BuildContext context) {
    final code = TextEditingController(), start = TextEditingController(), end = TextEditingController();
    return _Form(
      title: 'Add semester term',
      help: 'Create one term per semester, before anything else.',
      action: 'Create semester term',
      onSubmit: onSubmit,
      fields: (_) => [
        _field(code, 'Semester term code (e.g. 2026-ODD)', max: 32,
            helper: 'Use YEAR-ODD or YEAR-EVEN. 2026-ODD is shown as "Odd Semester 2026".'),
        _field(start, 'Start date (YYYY-MM-DD)', validator: _date,
            helper: 'First teaching day, e.g. 2026-08-03 from the timetable\'s w.e.f. date.'),
        _field(end, 'End date (YYYY-MM-DD)', validator: _date, helper: 'Last teaching day of the semester.'),
      ],
      collect: () => {'code': code.text.trim(), 'starts_on': start.text.trim(), 'ends_on': end.text.trim()},
    );
  }
}

class _CourseForm extends StatelessWidget {
  const _CourseForm({required this.onSubmit});
  final _Submit onSubmit;
  @override
  Widget build(BuildContext context) {
    final code = TextEditingController(), title = TextEditingController();
    return _Form(
      title: 'Add subject',
      help: 'Add each subject once; the same subject can be allocated to several sections.',
      action: 'Create subject',
      onSubmit: onSubmit,
      fields: (_) => [
        _field(code, 'Subject code (e.g. BCS 201)', max: 32, helper: 'As written on the timetable.'),
        _field(title, 'Subject name', helper: 'e.g. Design & Analysis of Algorithm.'),
      ],
      collect: () => {'code': code.text.trim(), 'title': title.text.trim()},
    );
  }
}

class _GroupForm extends StatefulWidget {
  const _GroupForm({required this.terms, required this.onSubmit});
  final List<Academic> terms;
  final _Submit onSubmit;
  @override
  State<_GroupForm> createState() => _GroupFormState();
}

class _GroupFormState extends State<_GroupForm> {
  String? term;
  final branch = TextEditingController(), sem = TextEditingController(), section = TextEditingController();

  @override
  void dispose() {
    branch.dispose();
    sem.dispose();
    section.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    term ??= widget.terms.length == 1 ? widget.terms.first.id : null;
    return _Form(
      title: 'Add section',
      help: 'A section is one group of students, e.g. CSE · 3rd Semester · CSE1.',
      action: 'Create section',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _Dropdown(
          label: 'Semester term',
          value: term,
          items: {for (final t in widget.terms) t.id: t.label},
          empty: 'Create a semester term first.',
          onChanged: (v) {
            term = v;
            rebuild();
          },
        ),
        _field(branch, 'Branch (e.g. CSE)', max: 50, helper: 'As written on the timetable, e.g. CSE or MAC.'),
        _field(sem, 'Semester (1–20)', keyboard: TextInputType.number, max: 2,
            helper: 'A number, e.g. 3 for 3rd Semester.', validator: (v) {
          final n = int.tryParse(v?.trim() ?? '');
          return (n == null || n < 1 || n > 20) ? 'Enter 1–20.' : null;
        }),
        _field(section, 'Section (e.g. CSE1)', max: 32, helper: 'As written on the timetable, e.g. CSE1 or CSE2.'),
      ],
      collect: () {
        if (term == null) return null;
        return {
          'term_id': term,
          'branch': branch.text.trim(),
          'semester': int.parse(sem.text.trim()),
          'section': section.text.trim(),
        };
      },
    );
  }
}

class _OfferingForm extends StatefulWidget {
  const _OfferingForm({required this.courses, required this.groups, required this.onSubmit});
  final List<Academic> courses, groups;
  final _Submit onSubmit;
  @override
  State<_OfferingForm> createState() => _OfferingFormState();
}

class _OfferingFormState extends State<_OfferingForm> {
  String? course, group;
  final title = TextEditingController();

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Form(
      title: 'Allocate subject to a section',
      help: 'Repeat for every subject each section studies.',
      action: 'Allocate subject',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _Dropdown(
          label: 'Subject',
          value: course,
          items: {for (final c in widget.courses) c.id: c.label},
          empty: 'Add a subject first.',
          onChanged: (v) {
            course = v;
            // Pre-fill the display title with the subject name the first time.
            final picked = widget.courses.where((c) => c.id == v).firstOrNull;
            if (title.text.trim().isEmpty && picked?.title != null) title.text = picked!.title!;
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Section',
          value: group,
          items: {for (final g in widget.groups) g.id: g.label},
          empty: 'Add a section first.',
          onChanged: (v) {
            group = v;
            rebuild();
          },
        ),
        _field(title, 'Display title', helper: 'Shown to faculty and students. Filled in from the subject name.'),
      ],
      collect: () {
        if (course == null || group == null) return null;
        return {'course_id': course, 'class_group_id': group, 'title': title.text.trim()};
      },
    );
  }
}

class _IdentityForm extends StatefulWidget {
  const _IdentityForm({
    required this.title,
    required this.numberLabel,
    required this.numberHelp,
    required this.onSubmit,
  });
  final String title, numberLabel, numberHelp;
  final _Submit onSubmit;
  @override
  State<_IdentityForm> createState() => _IdentityFormState();
}

class _IdentityFormState extends State<_IdentityForm> {
  bool login = false;
  final number = TextEditingController(),
      name = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController();

  @override
  void dispose() {
    for (final c in [number, name, email, password]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Form(
      title: widget.title,
      action: 'Create',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _field(number, widget.numberLabel, max: 32, helper: widget.numberHelp),
        _field(name, 'Full name', max: 100, helper: 'Official name as on institute records.'),
        _field(email, 'Official email', keyboard: TextInputType.emailAddress, max: 254, validator: _email,
            helper: 'Must match the email the person signs in with.'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Also create a login account'),
          subtitle: const Text('The person can sign in straight away with a temporary password you share privately.'),
          value: login,
          onChanged: (v) {
            login = v;
            rebuild();
          },
        ),
        if (login)
          _field(password, 'Temporary password (min 8)', max: 128,
              helper: 'Share it privately; never by email or chat.', validator: (v) {
            final t = (v ?? '').trim();
            return t.length < 8 ? 'At least 8 characters.' : null;
          }),
      ],
      collect: () => {
        'number': number.text.trim(),
        'official_name': name.text.trim(),
        'official_email': email.text.trim(),
        'create_login': login,
        if (login) 'password': password.text,
      },
    );
  }
}

class _AssignForm extends StatefulWidget {
  const _AssignForm({required this.offerings, required this.teachers, required this.onSubmit});
  final List<Offering> offerings;
  final List<Json> teachers;
  final _Submit onSubmit;
  @override
  State<_AssignForm> createState() => _AssignFormState();
}

class _AssignFormState extends State<_AssignForm> {
  String? offering, teacher;
  bool canFinalize = true;
  @override
  Widget build(BuildContext context) {
    return _Form(
      title: 'Assign faculty to a subject',
      help: 'The faculty member then sees this subject, its students and its attendance.',
      action: 'Assign',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _Dropdown(
          label: 'Subject',
          value: offering,
          items: {for (final o in widget.offerings) o.id: '${o.title} · ${o.subtitle}'},
          empty: 'Allocate a subject to a section first.',
          onChanged: (v) {
            offering = v;
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Faculty',
          value: teacher,
          items: {
            for (final t in widget.teachers)
              t['id'] as String: '${t['official_name']} (${t['employee_number']})',
          },
          empty: 'Add faculty first.',
          onChanged: (v) {
            teacher = v;
            rebuild();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Can publish attendance'),
          subtitle: const Text('Lets this faculty member finalize and publish attendance for the subject.'),
          value: canFinalize,
          onChanged: (v) {
            canFinalize = v;
            rebuild();
          },
        ),
      ],
      collect: () {
        if (offering == null || teacher == null) return null;
        return {'offering_id': offering, 'teacher_id': teacher, 'can_finalize': canFinalize};
      },
    );
  }
}

class _RoleForm extends StatefulWidget {
  const _RoleForm({required this.teachers, required this.students, required this.onSubmit});
  final List<Json> teachers, students;
  final _Submit onSubmit;
  @override
  State<_RoleForm> createState() => _RoleFormState();
}

class _RoleFormState extends State<_RoleForm> {
  String role = 'teacher', status = 'active';
  String? person;
  bool advanced = false;
  final userId = TextEditingController();

  @override
  void dispose() {
    userId.dispose();
    super.dispose();
  }

  /// Everyone with a linked login account, keyed by their account id.
  Map<String, String> get _people => {
    for (final t in widget.teachers)
      if (t['auth_user_id'] != null)
        t['auth_user_id'] as String: '${t['official_name']} (${t['employee_number']}) · Faculty',
    for (final s in widget.students)
      if (s['auth_user_id'] != null)
        s['auth_user_id'] as String: '${s['official_name']} (${s['enrollment_number']}) · Student',
  };

  @override
  Widget build(BuildContext context) {
    final people = _people;
    return _Form(
      title: 'Grant a role to an existing account',
      help: 'Use this to make someone Faculty or Admin, or to suspend access. Only people with a login account are listed.',
      action: 'Update role',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        if (!advanced)
          _Dropdown(
            label: 'Person with a login account',
            value: person,
            items: people,
            empty: 'Nobody has a login account yet. Create one in People, or enter an account ID below.',
            onChanged: (v) {
              person = v;
              final isStudent = widget.students.any((s) => s['auth_user_id'] == v);
              role = isStudent ? 'student' : 'teacher';
              rebuild();
            },
          )
        else
          _field(userId, 'Account user id (UUID)', max: 36,
              helper: 'Only needed for accounts not listed above.', validator: (v) {
            final ok = RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch((v ?? '').trim());
            return ok ? null : 'Enter the account UUID.';
          }),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              advanced = !advanced;
              rebuild();
            },
            child: Text(advanced ? 'Choose from the list instead' : 'Advanced: enter an account ID'),
          ),
        ),
        _Dropdown(
          label: 'Role',
          value: role,
          items: const {'student': 'Student', 'teacher': 'Faculty', 'admin': 'Admin'},
          onChanged: (v) {
            role = v!;
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Status',
          value: status,
          items: const {'active': 'Active', 'suspended': 'Suspended', 'pending': 'Pending'},
          onChanged: (v) {
            status = v!;
            rebuild();
          },
        ),
      ],
      collect: () {
        final id = advanced ? userId.text.trim() : person;
        if (id == null || id.isEmpty) return null;
        return {'auth_user_id': id, 'role': role, 'status': status};
      },
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.empty,
  });
  final String label;
  final String? value, empty;
  final Map<String, String> items;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: items.containsKey(value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            helperText: items.isEmpty ? empty : null,
            helperMaxLines: 3,
          ),
          items: [
            for (final e in items.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
          validator: (v) => v == null ? 'Select $label.' : null,
        ),
      );
}

class _Callout extends StatelessWidget {
  const _Callout({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: primary.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: primary),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(height: 1.45))),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            Padding(padding: const EdgeInsets.only(left: 30), child: action!),
          ],
        ],
      ),
    );
  }
}

/// "Already created" list under a form, so admins avoid duplicates.
class _Existing extends StatefulWidget {
  const _Existing(this.noun, this.items);
  final String noun;
  final List<String> items;
  @override
  State<_Existing> createState() => _ExistingState();
}

class _ExistingState extends State<_Existing> {
  bool open = false;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) {
      return _Note('No ${widget.noun} yet.');
    }
    final q = _search.text.trim().toLowerCase();
    final shown = items.where((i) => q.isEmpty || i.toLowerCase().contains(q)).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => setState(() => open = !open),
            icon: Icon(open ? Icons.expand_less : Icons.expand_more),
            label: Text('${open ? 'Hide' : 'Show'} ${items.length} existing ${widget.noun}'),
          ),
          if (open) ...[
            if (items.length > 8)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search ${widget.noun}',
                  ),
                ),
              ),
            for (final i in shown.take(100))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(i)),
                  ],
                ),
              ),
            if (shown.length > 100) _Note('+ ${shown.length - 100} more. Refine the search.'),
          ],
        ],
      ),
    );
  }
}

/// Searchable people list with login status.
class _Directory extends StatefulWidget {
  const _Directory({
    required this.title,
    required this.people,
    required this.numberKey,
    required this.onCreateLogin,
  });
  final String title, numberKey;
  final List<Json> people;
  final Future<bool> Function(Json person, String password) onCreateLogin;
  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  final _search = TextEditingController();

  Future<void> _createLogin(Json person) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _LoginDialog(person: person),
    );
    if (password != null) await widget.onCreateLogin(person, password);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _search.text.trim().toLowerCase();
    final shown = widget.people.where((p) {
      if (q.isEmpty) return true;
      return '${p['official_name']} ${p[widget.numberKey]} ${p['official_email']}'
          .toLowerCase()
          .contains(q);
    }).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.title} (${widget.people.length})', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            if (widget.people.isEmpty)
              const Text('Nobody added yet.')
            else ...[
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: 'Search name, number or email',
                ),
              ),
              const SizedBox(height: 8),
              if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No one matches this search.'),
                ),
              for (final p in shown.take(50))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p['official_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              '${p[widget.numberKey]} · ${p['official_email'] ?? ''}',
                              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (p['auth_user_id'] != null)
                        const Flexible(
                          child: Text(
                            'Login linked',
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _green),
                          ),
                        )
                      else
                        Flexible(
                          child: TextButton(
                            onPressed: () => _createLogin(p),
                            child: const Text('Create login'),
                          ),
                        ),
                    ],
                  ),
                ),
              if (shown.length > 50) _Note('+ ${shown.length - 50} more. Refine the search.'),
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks for a temporary password for an existing record's login account.
class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.person});
  final Json person;
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _key = GlobalKey<FormState>();
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    return AlertDialog(
      title: Text('Create login for ${p['official_name']}'),
      content: Form(
        key: _key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('They will sign in with ${p['official_email']} and this temporary password.'),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              maxLength: 128,
              decoration: const InputDecoration(
                labelText: 'Temporary password (min 8)',
                helperText: 'Share it privately; never by email or chat.',
                counterText: '',
              ),
              validator: (v) => (v ?? '').trim().length < 8 ? 'At least 8 characters.' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_key.currentState!.validate()) Navigator.pop(context, _password.text);
          },
          child: const Text('Create login'),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, height: 1.5),
        ),
      );
}
