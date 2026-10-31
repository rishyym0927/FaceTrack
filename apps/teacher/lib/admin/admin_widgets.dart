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
      padding: const EdgeInsets.only(bottom: 12),
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
                  Text(
                    subtitle!,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
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
  const _EmptyHint({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// Opens [form] in a dialog: a centred card on wide screens, full screen on
/// phones so the keyboard never hides the fields.
Future<void> _showFormDialog(BuildContext context, Widget form) {
  final narrow = MediaQuery.sizeOf(context).width < 600;
  final body = SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: form,
  );
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
              body: body,
            ),
          )
        : Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: body,
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
