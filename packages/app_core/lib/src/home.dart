import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'notifications.dart';
import 'widgets.dart';

/// Makes the app's [NotificationCenter] available to pages such as the home
/// screen's attention card. Absent when the app has no notifications.
class NotificationScope extends InheritedNotifier<NotificationCenter> {
  const NotificationScope({
    super.key,
    required NotificationCenter super.notifier,
    required super.child,
  });
  static NotificationCenter? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NotificationScope>()?.notifier;
}

String greeting([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

/// First name for a greeting, or null when no name is known.
String? firstName(String? fullName) {
  final parts = (fullName ?? '').trim().split(RegExp(r'\s+'));
  return parts.first.isEmpty ? null : parts.first;
}

/// Compact branded banner at the top of a home screen.
class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
  });
  final String title, subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff0d2a2c), Color(0xff135f50), Color(0xff23906f)],
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -.5,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(color: Color(0xffd5e9e2), height: 1.45),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 18),
          Theme(
            data: Theme.of(context).copyWith(
              filledButtonTheme: FilledButtonThemeData(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xff135f50),
                ),
              ),
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0x66ffffff)),
                ),
              ),
            ),
            child: Wrap(spacing: 10, runSpacing: 10, children: actions),
          ),
        ],
      ],
    ),
  );
}

/// Up to three items that need the reader, taken from notifications, with a
/// link to the full list. Hidden when the app has no notifications.
class AttentionCard extends StatelessWidget {
  const AttentionCard({super.key, this.limit = 3});
  final int limit;
  @override
  Widget build(BuildContext context) {
    final center = NotificationScope.of(context);
    if (center == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final urgent = [
      for (final n in center.items)
        if (n.tone == NoticeTone.action || n.tone == NoticeTone.warning) n,
    ];
    final Widget body;
    if (center.loading && center.items.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    } else if (urgent.isEmpty) {
      body = Row(
        children: [
          const Icon(Icons.check_circle_outline, color: Color(0xff1d7a4f)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Nothing needs your attention right now.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    } else {
      body = Column(
        children: [
          for (final n in urgent.take(limit))
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                center.markRead(n);
                if (n.route != null) context.go(n.route!);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      n.icon,
                      color: n.tone == NoticeTone.warning
                          ? const Color(0xffa15c07)
                          : scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        n.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Panel(
      padding: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                urgent.isEmpty
                    ? 'You are all set'
                    : 'Needs your attention · ${urgent.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton(
                onPressed: () => context.go('/notifications'),
                child: const Text('All notifications'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 12),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(text, style: Theme.of(context).textTheme.titleLarge),
        ?trailing,
      ],
    ),
  );
}

/// One subject as a single tappable row: icon, name, details, and either a
/// status badge or a chevron.
class SubjectTile extends StatelessWidget {
  const SubjectTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.menu_book_outlined,
    this.status,
    this.note,
    this.onTap,
  });
  final String title, subtitle;
  final IconData icon;
  final String? status, note;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .08),
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
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        note!,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (status != null) ...[
                      const SizedBox(height: 8),
                      StatusBadge(status!),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
