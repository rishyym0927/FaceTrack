part of '../teacher_admin.dart';

/// Sends a form; returns null on success or the message to show in the form.
typedef _Submit = Future<String?> Function(Json body);

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
  String? error;

  Future<void> _submit() async {
    if (busy || !_key.currentState!.validate()) return;
    final body = widget.collect();
    if (body == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    final problem = await widget.onSubmit(body);
    if (!mounted) return;
    setState(() {
      busy = false;
      error = problem;
    });
    // Forms open in a dialog: close it once the record exists.
    if (problem == null) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Form(
      key: _key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          if (widget.help != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.help!,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),
          ...widget.fields(() => setState(() {})),
          if (error != null)
            Container(
              margin: const EdgeInsets.only(top: 4, bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      error!,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).maybePop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: busy ? null : _submit,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(busy ? 'Saving…' : widget.action),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _field(
  TextEditingController c,
  String label, {
  String? helper,
  TextInputType? keyboard,
  int max = 150,
  String? Function(String?)? validator,
}) => Padding(
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
  if (v == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v.trim())) {
    return 'Use YYYY-MM-DD.';
  }
  return null;
}

String? _email(String? v) {
  if (v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) {
    return 'Enter a valid email.';
  }
  return null;
}

class _TermForm extends StatefulWidget {
  const _TermForm({required this.onSubmit});
  final _Submit onSubmit;
  @override
  State<_TermForm> createState() => _TermFormState();
}

class _TermFormState extends State<_TermForm> {
  final code = TextEditingController(),
      start = TextEditingController(),
      end = TextEditingController();

  @override
  void dispose() {
    for (final c in [code, start, end]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSubmit = widget.onSubmit;
    return _Form(
      title: 'Add semester term',
      help: 'Create one term per semester, before anything else.',
      action: 'Create semester term',
      onSubmit: onSubmit,
      fields: (_) => [
        _field(
          code,
          'Semester term code (e.g. 2026-ODD)',
          max: 32,
          helper: 'Use YEAR-ODD or YEAR-EVEN. 2026-ODD is shown as "Odd Semester 2026".',
        ),
        _field(
          start,
          'Start date (YYYY-MM-DD)',
          validator: _date,
          helper: 'First teaching day, e.g. 2026-08-03 from the timetable\'s w.e.f. date.',
        ),
        _field(
          end,
          'End date (YYYY-MM-DD)',
          validator: _date,
          helper: 'Last teaching day of the semester.',
        ),
      ],
      collect: () => {
        'code': code.text.trim(),
        'starts_on': start.text.trim(),
        'ends_on': end.text.trim(),
      },
    );
  }
}

class _CourseForm extends StatefulWidget {
  const _CourseForm({required this.onSubmit});
  final _Submit onSubmit;
  @override
  State<_CourseForm> createState() => _CourseFormState();
}

class _CourseFormState extends State<_CourseForm> {
  final code = TextEditingController(), title = TextEditingController();

  @override
  void dispose() {
    code.dispose();
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSubmit = widget.onSubmit;
    return _Form(
      title: 'Add subject',
      help: 'Add each subject once; the same subject can be allocated to several class groups.',
      action: 'Create subject',
      onSubmit: onSubmit,
      fields: (_) => [
        _field(
          code,
          'Subject code (e.g. BCS 201)',
          max: 32,
          helper: 'As written on the timetable.',
        ),
        _field(
          title,
          'Subject name',
          helper: 'e.g. Design & Analysis of Algorithm.',
        ),
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
  final branch = TextEditingController(), sem = TextEditingController();

  @override
  void dispose() {
    branch.dispose();
    sem.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    term ??= widget.terms.length == 1 ? widget.terms.first.id : null;
    return _Form(
      title: 'Add class group',
      help: 'A class group combines a branch and semester for one term.',
      action: 'Create class group',
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
        _field(
          branch,
          'Branch (e.g. CSE)',
          max: 50,
          helper: 'As written on the timetable, e.g. CSE or MAC.',
        ),
        _field(
          sem,
          'Semester (1–20)',
          keyboard: TextInputType.number,
          max: 2,
          helper: 'A number, e.g. 3 for 3rd Semester.',
          validator: (v) {
            final n = int.tryParse(v?.trim() ?? '');
            return (n == null || n < 1 || n > 20) ? 'Enter 1–20.' : null;
          },
        ),
      ],
      collect: () {
        if (term == null) return null;
        return {
          'term_id': term,
          'branch': branch.text.trim(),
          'semester': int.parse(sem.text.trim()),
        };
      },
    );
  }
}

class _OfferingForm extends StatefulWidget {
  const _OfferingForm({
    required this.courses,
    required this.groups,
    required this.onSubmit,
  });
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
      title: 'Allocate subject to a class group',
      help: 'Repeat for every subject each class group studies.',
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
            if (title.text.trim().isEmpty && picked?.title != null) {
              title.text = picked!.title!;
            }
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Section',
          value: group,
          items: {for (final g in widget.groups) g.id: g.label},
          empty: 'Add a class group first.',
          onChanged: (v) {
            group = v;
            rebuild();
          },
        ),
        _field(
          title,
          'Display title',
          helper:
              'Shown to faculty and students. Filled in from the subject name.',
        ),
      ],
      collect: () {
        if (course == null || group == null) return null;
        return {
          'course_id': course,
          'class_group_id': group,
          'title': title.text.trim(),
        };
      },
    );
  }
}

class _IdentityForm extends StatefulWidget {
  const _IdentityForm({
    required this.title,
    this.numberLabel,
    this.numberHelp,
    required this.onSubmit,
  });
  final String title;
  final String? numberLabel, numberHelp;
  final _Submit onSubmit;
  @override
  State<_IdentityForm> createState() => _IdentityFormState();
}

class _IdentityFormState extends State<_IdentityForm> {
  bool login = false, reveal = false;
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
        if (widget.numberLabel case final label?)
          _field(number, label, max: 32, helper: widget.numberHelp),
        _field(
          name,
          'Full name',
          max: 100,
          helper: 'Official name as on institute records.',
        ),
        _field(
          email,
          'Official email',
          keyboard: TextInputType.emailAddress,
          max: 254,
          validator: _email,
          helper: 'Must match the email the person signs in with.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Also create a login account'),
          subtitle: const Text(
            'The person can sign in straight away with a temporary password you share privately.',
          ),
          value: login,
          onChanged: (v) {
            login = v;
            rebuild();
          },
        ),
        if (login)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextFormField(
              controller: password,
              obscureText: !reveal,
              maxLength: 128,
              decoration: InputDecoration(
                labelText: 'Temporary password (min 8)',
                helperText: 'Share it privately; never by email or chat.',
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: reveal ? 'Hide password' : 'Show password',
                  icon: Icon(reveal ? Icons.visibility_off : Icons.visibility),
                  onPressed: () {
                    reveal = !reveal;
                    rebuild();
                  },
                ),
              ),
              validator: (v) =>
                  (v ?? '').trim().length < 8 ? 'At least 8 characters.' : null,
            ),
          ),
      ],
      collect: () => {
        if (widget.numberLabel != null) 'number': number.text.trim(),
        'official_name': name.text.trim(),
        'official_email': email.text.trim(),
        'create_login': login,
        if (login) 'password': password.text,
      },
    );
  }
}

class _AssignForm extends StatefulWidget {
  const _AssignForm({
    required this.offerings,
    required this.teachers,
    required this.onSubmit,
  });
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
          items: {
            for (final o in widget.offerings)
              o.id: '${o.title} · ${o.subtitle}',
          },
          empty: 'Allocate a subject to a class group first.',
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
              t['id'] as String:
                  '${t['official_name']} (${t['official_email']})',
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
          subtitle: const Text(
            'Lets this faculty member finalize and publish attendance for the subject.',
          ),
          value: canFinalize,
          onChanged: (v) {
            canFinalize = v;
            rebuild();
          },
        ),
      ],
      collect: () {
        if (offering == null || teacher == null) return null;
        return {
          'offering_id': offering,
          'teacher_id': teacher,
          'can_finalize': canFinalize,
        };
      },
    );
  }
}

class _RoleForm extends StatefulWidget {
  const _RoleForm({
    required this.teachers,
    required this.students,
    required this.onSubmit,
  });
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
        t['auth_user_id'] as String:
            '${t['official_name']} (${t['official_email']}) · Faculty',
    for (final s in widget.students)
      if (s['auth_user_id'] != null)
        s['auth_user_id'] as String:
            '${s['official_name']} (${s['enrollment_number']}) · Student',
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
              final isStudent = widget.students.any(
                (s) => s['auth_user_id'] == v,
              );
              role = isStudent ? 'student' : 'teacher';
              rebuild();
            },
          )
        else
          _field(
            userId,
            'Account user id (UUID)',
            max: 36,
            helper: 'Only needed for accounts not listed above.',
            validator: (v) {
              final ok = RegExp(r'^[0-9a-fA-F-]{36}$')
                  .hasMatch((v ?? '').trim());
              return ok ? null : 'Enter the account UUID.';
            },
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              advanced = !advanced;
              rebuild();
            },
            child: Text(
              advanced
                  ? 'Choose from the list instead'
                  : 'Advanced: enter an account ID',
            ),
          ),
        ),
        _Dropdown(
          label: 'Role',
          value: role,
          items: const {
            'student': 'Student',
            'teacher': 'Faculty',
            'admin': 'Admin',
          },
          onChanged: (v) {
            role = v!;
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Status',
          value: status,
          items: const {
            'active': 'Active',
            'suspended': 'Suspended',
            'pending': 'Pending',
          },
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
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
      validator: (v) => v == null ? 'Select $label.' : null,
    ),
  );
}

enum _LoginFilter { all, linked, missing }

/// Searchable people list with login status and a login filter.
class _Directory extends StatefulWidget {
  const _Directory({
    super.key,
    required this.title,
    required this.people,
    required this.numberKey,
    required this.onCreateLogin,
    this.fresh,
  });
  final String title;
  final String? numberKey;
  final List<Json> people;
  final Future<String?> Function(Json person, String password) onCreateLogin;

  /// Number of a just-created person, briefly highlighted.
  final String? fresh;
  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  final _search = TextEditingController();
  _LoginFilter filter = _LoginFilter.all;

  /// People whose login is being created, so a second tap does nothing.
  final _creating = <Object?>{};

  Future<void> _createLogin(Json person) async {
    if (_creating.contains(person['id'])) return;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _LoginDialog(person: person),
    );
    if (password == null || !mounted) return;
    setState(() => _creating.add(person['id']));
    try {
      await widget.onCreateLogin(person, password);
    } finally {
      if (mounted) setState(() => _creating.remove(person['id']));
    }
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
    final linked = widget.people.where((p) => p['auth_user_id'] != null).length;
    final shown = widget.people.where((p) {
      final has = p['auth_user_id'] != null;
      if (filter == _LoginFilter.linked && !has) return false;
      if (filter == _LoginFilter.missing && has) return false;
      if (q.isEmpty) return true;
      return '${p['official_name']} ${p[widget.numberKey] ?? ''} ${p['official_email']}'
          .toLowerCase()
          .contains(q);
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${widget.title} (${widget.people.length})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 10),
        if (widget.people.isEmpty)
          const _EmptyHint(
            icon: Icons.person_add_alt_1_outlined,
            text: 'Nobody added yet. Use the Add button above to create the first record.',
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (f, label) in [
                (_LoginFilter.all, 'All ${widget.people.length}'),
                (_LoginFilter.linked, 'With login $linked'),
                (
                  _LoginFilter.missing,
                  'Needs login ${widget.people.length - linked}',
                ),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: filter == f,
                  onSelected: (_) => setState(() => filter = f),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: widget.numberKey == null
                  ? 'Search name or email'
                  : 'Search name, number or email',
            ),
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No one matches this search or filter.'),
            ),
          for (final p in shown.take(50))
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color:
                    widget.fresh != null &&
                        (p[widget.numberKey ?? 'official_email'] as String?)
                                ?.toLowerCase() ==
                            widget.fresh?.toLowerCase()
                    ? _green.withValues(alpha: .10)
                    : theme.colorScheme.surfaceContainerLowest,
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: .10,
                    ),
                    child: Text(
                      _initials('${p['official_name']}'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${p['official_name']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          [
                            if (widget.numberKey != null) p[widget.numberKey],
                            p['official_email'],
                          ].whereType<String>().join(' · '),
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (p['auth_user_id'] != null)
                    const Flexible(
                      child: Tooltip(
                        message: 'This person can sign in.',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              size: 16,
                              color: _green,
                            ),
                            SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Login linked',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: _green,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: Tooltip(
                        message: 'Give this person a login with a temporary password.',
                        child: TextButton(
                          onPressed: _creating.contains(p['id'])
                              ? null
                              : () => _createLogin(p),
                          child: Text(
                            _creating.contains(p['id'])
                                ? 'Creating…'
                                : 'Create login',
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (shown.length > 50)
            _Note('+ ${shown.length - 50} more. Refine the search.'),
        ],
      ],
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty);
  final letters = parts.take(2).map((x) => x[0].toUpperCase()).join();
  return letters.isEmpty ? '?' : letters;
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
  bool reveal = false;
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
            Text(
              'They will sign in with ${p['official_email']} and this temporary password.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: !reveal,
              maxLength: 128,
              decoration: InputDecoration(
                labelText: 'Temporary password (min 8)',
                helperText: 'Share it privately; never by email or chat.',
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: reveal ? 'Hide password' : 'Show password',
                  icon: Icon(reveal ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => reveal = !reveal),
                ),
              ),
              validator: (v) =>
                  (v ?? '').trim().length < 8 ? 'At least 8 characters.' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_key.currentState!.validate()) {
              Navigator.pop(context, _password.text);
            }
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
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 13,
        height: 1.5,
      ),
    ),
  );
}
