import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

/// Administrative provisioning: academic structure, identities and roles.
/// Every write calls a /v1/admin/* endpoint backed by an app.admin_* database
/// function that re-checks the caller is an active admin, so this screen is a
/// convenience over a server that enforces the rules itself.
class TeacherAdmin extends ConsumerStatefulWidget {
  const TeacherAdmin({super.key});
  @override
  ConsumerState<TeacherAdmin> createState() => _TeacherAdminState();
}

enum _Section { academics, people, roles }

class _TeacherAdminState extends ConsumerState<TeacherAdmin> {
  late final ApiClient api;
  late final String institute;
  _Section section = _Section.academics;
  bool loading = true;
  String? loadError;

  List<Academic> terms = [], courses = [], groups = [];
  List<Offering> offerings = [];
  List<Map<String, dynamic>> teachers = [];

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final lists = await Future.wait([
        api.academics(institute, 'terms'),
        api.academics(institute, 'courses'),
        api.academics(institute, 'class-groups'),
        api.offerings(institute),
        api.send('GET', '/v1/admin/teachers', institute: institute),
      ]);
      if (!mounted) return;
      setState(() {
        terms = lists[0] as List<Academic>;
        courses = lists[1] as List<Academic>;
        groups = lists[2] as List<Academic>;
        offerings = (lists[3] as PageData<Offering>).items;
        teachers = ((lists[4] as Map)['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
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

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
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

  @override
  Widget build(BuildContext context) {
    return ContentPage(
      children: [
        const PageHeader(
          title: 'Administration',
          subtitle: 'Create academic structure, identities and roles for your institute.',
          eyebrow: 'Admin',
          icon: Icons.admin_panel_settings_outlined,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _Section.values)
              ChoiceChip(
                label: Text(switch (s) {
                  _Section.academics => 'Academics',
                  _Section.people => 'People',
                  _Section.roles => 'Roles & assignments',
                }),
                selected: section == s,
                onSelected: (_) => setState(() => section = s),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (loading)
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
            _Section.academics => _academics(),
            _Section.people => _people(),
            _Section.roles => _roles(),
          },
      ],
    );
  }

  // --- Academics -------------------------------------------------------------
  List<Widget> _academics() => [
        _TermForm(onSubmit: (body) => _run('Semester term created.', () => _post('/v1/admin/terms', body).then((_) {}))),
        const SizedBox(height: 16),
        _CourseForm(onSubmit: (body) => _run('Subject created.', () => _post('/v1/admin/courses', body).then((_) {}))),
        const SizedBox(height: 16),
        _GroupForm(
          terms: terms,
          onSubmit: (body) => _run('Section created.', () => _post('/v1/admin/class-groups', body).then((_) {})),
        ),
        const SizedBox(height: 16),
        _OfferingForm(
          courses: courses,
          groups: groups,
          onSubmit: (body) => _run('Subject allocated to the section.', () => _post('/v1/admin/offerings', body).then((_) {})),
        ),
      ];

  // --- People ----------------------------------------------------------------
  List<Widget> _people() => [
        _IdentityForm(
          title: 'Add faculty',
          numberLabel: 'Employee number',
          onSubmit: (body) => _run(
            body['create_login'] == true ? 'Faculty created with a login account.' : 'Faculty identity created.',
            () => _post('/v1/admin/teachers', body).then((_) {}),
          ),
        ),
        const SizedBox(height: 16),
        _IdentityForm(
          title: 'Add student',
          numberLabel: 'Enrolment number',
          onSubmit: (body) => _run(
            body['create_login'] == true ? 'Student created with a login account.' : 'Student identity created.',
            () => _post('/v1/admin/students', body).then((_) {}),
          ),
        ),
        const SizedBox(height: 8),
        const _Note(
          'Without a login account, a student signs up with the approved email and links their '
          'enrolment number. Faculty need a login account (or an existing one granted the faculty role).',
        ),
      ];

  // --- Roles & assignments ---------------------------------------------------
  List<Widget> _roles() => [
        _AssignForm(
          offerings: offerings,
          teachers: teachers,
          onSubmit: (body) => _run('Faculty assigned to the subject.', () => _post('/v1/admin/assignments', body).then((_) {})),
        ),
        const SizedBox(height: 16),
        _RoleForm(onSubmit: (body) => _run('Role updated.', () => _post('/v1/admin/memberships', body).then((_) {}))),
        const SizedBox(height: 8),
        const _Note(
          'Assigning faculty requires that account to already hold an active teacher role. '
          'Grant the role by the account user id below if needed.',
        ),
      ];
}

typedef _Submit = Future<bool> Function(Map<String, dynamic> body);

/// A small stateful wrapper giving each form its own key, busy state and submit button.
class _Form extends StatefulWidget {
  const _Form({
    required this.title,
    required this.action,
    required this.fields,
    required this.collect,
    required this.onSubmit,
  });
  final String title, action;
  final List<Widget> Function(void Function() rebuild) fields;
  final Map<String, dynamic>? Function() collect;
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

Widget _field(TextEditingController c, String label, {TextInputType? keyboard, int max = 150, String? Function(String?)? validator}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        keyboardType: keyboard,
        maxLength: max,
        decoration: InputDecoration(labelText: label, counterText: ''),
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
      action: 'Create semester term',
      onSubmit: onSubmit,
      fields: (_) => [
        _field(code, 'Semester term code (e.g. 2026-ODD)', max: 32),
        _field(start, 'Start date (YYYY-MM-DD)', validator: _date),
        _field(end, 'End date (YYYY-MM-DD)', validator: _date),
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
      action: 'Create subject',
      onSubmit: onSubmit,
      fields: (_) => [
        _field(code, 'Subject code (e.g. BCS 201)', max: 32),
        _field(title, 'Subject name'),
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
  @override
  Widget build(BuildContext context) {
    final branch = TextEditingController(), sem = TextEditingController(), section = TextEditingController();
    term ??= widget.terms.length == 1 ? widget.terms.first.id : null;
    return _Form(
      title: 'Add section',
      action: 'Create section',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _Dropdown(
          label: 'Semester term',
          value: term,
          items: {for (final t in widget.terms) t.id: t.label},
          onChanged: (v) {
            term = v;
            rebuild();
          },
        ),
        _field(branch, 'Branch (e.g. CSE)', max: 50),
        _field(sem, 'Semester (1–20)', keyboard: TextInputType.number, max: 2, validator: (v) {
          final n = int.tryParse(v?.trim() ?? '');
          return (n == null || n < 1 || n > 20) ? 'Enter 1–20.' : null;
        }),
        _field(section, 'Section (e.g. A)', max: 32),
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
  @override
  Widget build(BuildContext context) {
    final title = TextEditingController();
    return _Form(
      title: 'Allocate subject to a section',
      action: 'Allocate subject',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _Dropdown(
          label: 'Subject',
          value: course,
          items: {for (final c in widget.courses) c.id: c.label},
          onChanged: (v) {
            course = v;
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Section',
          value: group,
          items: {for (final g in widget.groups) g.id: g.label},
          onChanged: (v) {
            group = v;
            rebuild();
          },
        ),
        _field(title, 'Display title'),
      ],
      collect: () {
        if (course == null || group == null) return null;
        return {'course_id': course, 'class_group_id': group, 'title': title.text.trim()};
      },
    );
  }
}

class _IdentityForm extends StatefulWidget {
  const _IdentityForm({required this.title, required this.numberLabel, required this.onSubmit});
  final String title, numberLabel;
  final _Submit onSubmit;
  @override
  State<_IdentityForm> createState() => _IdentityFormState();
}

class _IdentityFormState extends State<_IdentityForm> {
  bool login = false;
  @override
  Widget build(BuildContext context) {
    final number = TextEditingController(),
        name = TextEditingController(),
        email = TextEditingController(),
        password = TextEditingController();
    return _Form(
      title: widget.title,
      action: 'Create',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _field(number, widget.numberLabel, max: 32),
        _field(name, 'Full name', max: 100),
        _field(email, 'Official email', keyboard: TextInputType.emailAddress, max: 254, validator: _email),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Also create a login account'),
          subtitle: const Text('Provisions a Supabase account the person can sign in with.'),
          value: login,
          onChanged: (v) {
            login = v;
            rebuild();
          },
        ),
        if (login)
          _field(password, 'Temporary password (min 8)', max: 128, validator: (v) {
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
  final List<Map<String, dynamic>> teachers;
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
      action: 'Assign',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _Dropdown(
          label: 'Subject',
          value: offering,
          items: {for (final o in widget.offerings) o.id: '${o.title} · ${o.subtitle}'},
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
          onChanged: (v) {
            teacher = v;
            rebuild();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Can finalize attendance'),
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
  const _RoleForm({required this.onSubmit});
  final _Submit onSubmit;
  @override
  State<_RoleForm> createState() => _RoleFormState();
}

class _RoleFormState extends State<_RoleForm> {
  String role = 'teacher', status = 'active';
  @override
  Widget build(BuildContext context) {
    final userId = TextEditingController();
    return _Form(
      title: 'Grant a role to an existing account',
      action: 'Update role',
      onSubmit: widget.onSubmit,
      fields: (rebuild) => [
        _field(userId, 'Account user id (UUID)', max: 36, validator: (v) {
          final ok = RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch((v ?? '').trim());
          return ok ? null : 'Enter the account UUID.';
        }),
        _Dropdown(
          label: 'Role',
          value: role,
          items: const {'student': 'Student', 'teacher': 'Teacher', 'admin': 'Admin'},
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
      collect: () => {'auth_user_id': userId.text.trim(), 'role': role, 'status': status},
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final String? value;
  final Map<String, String> items;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: items.containsKey(value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final e in items.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
          validator: (v) => v == null ? 'Select $label.' : null,
        ),
      );
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
