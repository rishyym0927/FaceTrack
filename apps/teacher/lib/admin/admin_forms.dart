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
          Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
          if (widget.help != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              widget.help!,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
          const SizedBox(height: AppSpace.xl),
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
          const Divider(height: AppSpace.xl),
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
      help: 'Add each subject once; the same subject can be allocated to several sections.',
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
      title: 'Add section',
      help: 'A section combines a branch and semester for one term.',
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
            if (title.text.trim().isEmpty && picked?.title != null) {
              title.text = picked!.title!;
            }
            rebuild();
          },
        ),
        _Dropdown(
          label: 'Section',
          value: group,
          items: {for (final g in widget.groups) g.id: _sectionLabel(g)},
          empty: 'Add a section first.',
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
    final wide =
        MediaQuery.sizeOf(context).width >= 760 &&
        MediaQuery.textScalerOf(context).scale(1) <= 1.3;
    final visible = shown.take(50).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${widget.title} (${widget.people.length})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpace.md),
        if (widget.people.isEmpty)
          const _EmptyHint(
            icon: Icons.person_add_alt_1_outlined,
            title: 'Nobody added yet',
            text: 'Use the Add button above to create the first record.',
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
                  showCheckmark: false,
                  onSelected: (_) => setState(() => filter = f),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
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
          const SizedBox(height: AppSpace.md),
          if (shown.isEmpty)
            const _EmptyHint(
              icon: Icons.search_off_outlined,
              title: 'No one matches',
              text: 'Try a different search or filter.',
            )
          else
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: Column(
                children: [
                  if (wide) _headerRow(theme),
                  for (final (i, p) in visible.indexed)
                    _personRow(theme, p, wide: wide, first: i == 0 && !wide),
                ],
              ),
            ),
          if (shown.length > 50)
            _Note('+ ${shown.length - 50} more. Refine the search.'),
        ],
      ],
    );
  }

  Widget _headerRow(ThemeData theme) {
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: .3,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      color: theme.colorScheme.surfaceContainerLowest,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      child: Row(
        children: [
          const SizedBox(width: 36 + AppSpace.md),
          Expanded(flex: 3, child: Text('Name', style: style)),
          if (widget.numberKey != null)
            Expanded(flex: 2, child: Text('Enrolment number', style: style)),
          Expanded(flex: 4, child: Text('Email', style: style)),
          SizedBox(
            width: 140,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('Login', style: style),
            ),
          ),
        ],
      ),
    );
  }

  Widget _personRow(
    ThemeData theme,
    Json p, {
    required bool wide,
    required bool first,
  }) {
    final linked = p['auth_user_id'] != null;
    final number = widget.numberKey == null
        ? null
        : p[widget.numberKey] as String?;
    final email = p['official_email'] as String?;
    final isFresh =
        widget.fresh != null &&
        (p[widget.numberKey ?? 'official_email'] as String?)?.toLowerCase() ==
            widget.fresh?.toLowerCase();
    final creating = _creating.contains(p['id']);
    final status = linked
        ? const Tooltip(
            message: 'This person can sign in.',
            child: TonePill(
              'Login linked',
              tone: AppTone.success,
              icon: Icons.verified_user_outlined,
            ),
          )
        : Tooltip(
            message: 'Give this person a login with a temporary password.',
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: creating ? null : () => _createLogin(p),
              child: Text(creating ? 'Creating…' : 'Create login'),
            ),
          );
    final avatar = CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.primary.withValues(alpha: .10),
      child: Text(
        _initials('${p['official_name']}'),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.primary,
        ),
      ),
    );
    final name = Text(
      '${p['official_name']}',
      style: const TextStyle(fontWeight: FontWeight.w700),
    );
    final muted = TextStyle(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 13,
    );
    final Widget row = wide
        ? Row(
            children: [
              avatar,
              const SizedBox(width: AppSpace.md),
              Expanded(flex: 3, child: name),
              if (widget.numberKey != null)
                Expanded(
                  flex: 2,
                  child: Text(number ?? '—', style: muted),
                ),
              Expanded(
                flex: 4,
                child: Text(
                  email ?? '—',
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 140,
                child: Align(alignment: Alignment.centerRight, child: status),
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              avatar,
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    name,
                    Text(
                      [number, email].whereType<String>().join(' · '),
                      style: muted,
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Align(alignment: Alignment.centerLeft, child: status),
                  ],
                ),
              ),
            ],
          );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: wide ? AppSpace.sm + 2 : AppSpace.md,
      ),
      decoration: BoxDecoration(
        color: isFresh ? _green.withValues(alpha: .10) : null,
        border: first
            ? null
            : Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: row,
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
