part of '../teacher_admin.dart';

typedef _AcademicEntry = ({
  String kind,
  String id,
  int? version,
  String label,
  Json fields,
  String? term,
});

class _AcademicManagement extends StatefulWidget {
  const _AcademicManagement({
    required this.terms,
    required this.courses,
    required this.groups,
    required this.offerings,
    required this.edit,
  });

  final List<Academic> terms, courses, groups;
  final List<Offering> offerings;
  final ValueChanged<_AcademicEntry> edit;

  @override
  State<_AcademicManagement> createState() => _AcademicManagementState();
}

class _AcademicManagementState extends State<_AcademicManagement> {
  String query = '';
  String? term;
  int shown = 15;

  Iterable<_AcademicEntry> get entries sync* {
    final codes = {for (final t in widget.terms) t.id: t.code};
    for (final t in widget.terms) {
      yield (
        kind: 'terms',
        id: t.id,
        version: t.version,
        label: t.label,
        fields: {'code': t.code, 'starts_on': t.startsOn, 'ends_on': t.endsOn},
        term: t.code,
      );
    }
    for (final c in widget.courses) {
      if (term != null &&
          !widget.offerings.any(
            (o) => o.termCode == term && o.courseCode == c.code,
          )) {
        continue;
      }
      yield (
        kind: 'courses',
        id: c.id,
        version: c.version,
        label: c.label,
        fields: {'code': c.code, 'title': c.title},
        term: term,
      );
    }
    for (final g in widget.groups) {
      yield (
        kind: 'class-groups',
        id: g.id,
        version: g.version,
        label: _sectionLabel(g),
        fields: {'semester': g.semester},
        term: codes[g.termId],
      );
    }
    for (final o in widget.offerings) {
      yield (
        kind: 'offerings',
        id: o.id,
        version: o.version,
        label: '${o.title} · ${o.subtitle}',
        fields: {'title': o.title},
        term: o.termCode,
      );
    }
  }

  static const labels = {
    'terms': 'Semester term',
    'courses': 'Catalog subject',
    'class-groups': 'Section',
    'offerings': 'Teaching allocation',
  };

  @override
  void didUpdateWidget(_AcademicManagement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (term != null && !widget.terms.any((t) => t.code == term)) term = null;
  }

  @override
  Widget build(BuildContext context) {
    final matches = entries
        .where(
          (row) =>
              (term == null || row.term == term) &&
              '${row.label} ${labels[row.kind]} ${row.term ?? ''}'
                  .toLowerCase()
                  .contains(query),
        )
        .take(shown + 1)
        .toList();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Manage academic records',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search academic records',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() {
              query = value.trim().toLowerCase();
              shown = 15;
            }),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey(term),
            initialValue: term ?? '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Semester term'),
            items: [
              const DropdownMenuItem(value: '', child: Text('All terms')),
              for (final t in widget.terms)
                if (t.code != null)
                  DropdownMenuItem(
                    value: t.code,
                    child: Text(t.label, overflow: TextOverflow.ellipsis),
                  ),
            ],
            onChanged: (value) => setState(() {
              term = value == '' ? null : value;
              shown = 15;
            }),
          ),
          if (matches.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No matching academic records.'),
            ),
          for (final row in matches.take(shown))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(row.label),
              subtitle: Text(
                [
                  labels[row.kind]!,
                  if (row.term != null && row.kind != 'terms') row.term!,
                ].join(' · '),
              ),
              trailing: IconButton(
                tooltip: 'Edit ${labels[row.kind]!.toLowerCase()}',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => widget.edit(row),
              ),
            ),
          if (matches.length > shown)
            TextButton(
              onPressed: () => setState(() => shown += 15),
              child: const Text('Show more records'),
            ),
        ],
      ),
    );
  }
}

class _AcademicEditor extends StatefulWidget {
  const _AcademicEditor({required this.row, required this.save});

  final _AcademicEntry row;
  final Future<void> Function(Json, Mutation) save;

  @override
  State<_AcademicEditor> createState() => _AcademicEditorState();
}

class _AcademicEditorState extends State<_AcademicEditor> {
  late final controllers = {
    for (final field in widget.row.fields.entries)
      field.key: TextEditingController(text: field.value?.toString() ?? ''),
  };

  static const _labels = {
    'code': 'Code',
    'title': 'Name',
    'starts_on': 'Start date (YYYY-MM-DD)',
    'ends_on': 'End date (YYYY-MM-DD)',
    'semester': 'Semester number',
  };

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? validate(String field, String? input) {
    final required = requiredText(input);
    if (required != null) return required;
    final value = input!.trim();
    if (field == 'semester') {
      final semester = int.tryParse(value);
      if (semester == null || semester < 1 || semester > 20) {
        return 'Enter 1 to 20.';
      }
    }
    if (field == 'starts_on' || field == 'ends_on') {
      final date = DateTime.tryParse(value);
      if (date == null || date.toIso8601String().split('T').first != value) {
        return 'Enter a valid date in YYYY-MM-DD format.';
      }
      final start = DateTime.tryParse(controllers['starts_on']!.text.trim());
      if (field == 'ends_on' && start != null && date.isBefore(start)) {
        return 'End date must be on or after the start date.';
      }
    }
    final max = field == 'title' ? 150 : 32;
    return value.length > max ? 'Use $max characters or fewer.' : null;
  }

  @override
  Widget build(BuildContext context) => ActionDialog(
    title:
        'Edit ${_AcademicManagementState.labels[widget.row.kind]!.toLowerCase()}',
    button: 'Save changes',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.row.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(switch (widget.row.kind) {
          'courses' => 'Code changes apply to all linked allocations. Edit an allocation to change its display name.',
          'offerings' =>
            'This display name applies only to this teaching allocation.',
          'terms' =>
            'These dates and this code apply to the entire semester term.',
          _ => 'This semester number applies to the section and all its allocations.',
        }),
        for (final field in controllers.entries) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: field.value,
            decoration: InputDecoration(labelText: _labels[field.key]),
            keyboardType: field.key == 'semester' ? TextInputType.number : null,
            validator: (value) => validate(field.key, value),
          ),
        ],
      ],
    ),
    submit: (mutation) => widget.save({
      for (final field in controllers.entries)
        field.key: field.key == 'semester'
            ? int.parse(field.value.text.trim())
            : field.value.text.trim(),
    }, mutation),
  );
}
