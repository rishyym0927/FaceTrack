part of '../teacher_admin.dart';

/// An ⓘ that explains a term: hover or long-press shows a tooltip, a tap opens
/// the full explanation (touch screens have no hover).
class _InfoTip extends StatelessWidget {
  const _InfoTip(this.title, this.text);
  final String title, text;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    waitDuration: const Duration(milliseconds: 300),
    child: IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.info_outline,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.lightbulb_outline),
          title: Text(title),
          content: Text(text, style: const TextStyle(height: 1.5)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A section heading with an optional explanation tip and trailing action.
class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.subtitle, this.tip, this.trailing});
  final String title;
  final String? subtitle;
  final _InfoTip? tip;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(title, style: theme.textTheme.titleLarge),
                    ),
                    ?tip,
                  ],
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.title, this.text});
  final IconData icon;
  final String title;
  final String? text;
  @override
  Widget build(BuildContext context) =>
      EmptyState(compact: true, icon: icon, title: title, message: text);
}

/// Opens [form] in a dialog: a centred card on wide screens, full screen on
/// phones so the keyboard never hides the fields.
Future<void> _showFormDialog(BuildContext context, Widget form) {
  final narrow = MediaQuery.sizeOf(context).width < 600;
  return showDialog<void>(
    context: context,
    builder: (context) => narrow
        ? Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: form,
              ),
            ),
          )
        : Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xxl,
                  AppSpace.xl + 4,
                  AppSpace.xxl,
                  AppSpace.xl,
                ),
                child: form,
              ),
            ),
          ),
  );
}

/// A searchable read-only list in a dialog ("View all").
Future<void> _showListDialog(
  BuildContext context,
  String title,
  List<String> items,
) => showDialog<void>(
  context: context,
  builder: (context) => _ListDialog(title: title, items: items),
);

class _ListDialog extends StatefulWidget {
  const _ListDialog({required this.title, required this.items});
  final String title;
  final List<String> items;
  @override
  State<_ListDialog> createState() => _ListDialogState();
}

class _ListDialogState extends State<_ListDialog> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    final shown = [
      for (final i in widget.items)
        if (q.isEmpty || i.toLowerCase().contains(q)) i,
    ];
    return AlertDialog(
      title: Text('${widget.title} (${widget.items.length})'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => query = v),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Search ${widget.title.toLowerCase()}',
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('Nothing matches.'))
                  : ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) =>
                          ListTile(dense: true, title: Text(shown[i])),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// "CSE · 3rd Semester" or "CSE · 3rd Semester · Section CSE1". A section with
/// no section letter is just branch and semester.
String _sectionLabel(Academic g) {
  final letter = g.section;
  if (g.semester == null || (letter != null && letter != 'ALL')) return g.label;
  return '${g.branch} · ${semesterLabel(g.semester!)}';
}
