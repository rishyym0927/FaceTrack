import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Faculty-specific cards in the Account page's slot, below the profile
/// header: shortcuts to the faculty tools and a short note about the app.
///
/// The profile header, institute switch and sign out come from the shared
/// Account page. Attendance details live in the dedicated tab, so nothing
/// here makes a request or keeps a copy of attendance numbers that could go
/// stale.
class TeacherAccountStats extends StatelessWidget {
  const TeacherAccountStats({super.key, this.version});

  /// App version, shown only when the build supplies one (`APP_VERSION`).
  final String? version;

  static const _buildVersion = String.fromEnvironment('APP_VERSION');

  @override
  Widget build(BuildContext context) {
    final shown = (version ?? _buildVersion).trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupLabel('Faculty tools'),
        Panel(
          padding: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ToolRow(
                icon: Icons.insights_outlined,
                title: 'Attendance',
                message: 'View published results and students below 75%.',
                button: 'Open attendance',
                onTap: () => context.go('/attendance'),
              ),
              const Divider(height: 1),
              _ToolRow(
                icon: Icons.class_outlined,
                title: 'Subjects',
                message:
                    'Start a class session, review attendance and manage students.',
                button: 'Open subjects',
                onTap: () => context.go('/classes'),
              ),
            ],
          ),
        ),
        const _GroupLabel('About this app'),
        Panel(
          padding: AppSpace.lg,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FaceTrackMark(size: 44),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'FaceTrack Faculty',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (shown.isNotEmpty)
                          TonePill('Version $shown', tone: AppTone.neutral),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      'Face recognition only drafts attendance. Nothing is published until you have reviewed it.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.xs,
      AppSpace.xs,
      AppSpace.xs,
      AppSpace.sm,
    ),
    child: Semantics(
      header: true,
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: .8,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

/// One shortcut: icon tile, title and sentence, and a clear button. The whole
/// row is tappable; the button keeps the action obvious and reachable.
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.icon,
    required this.title,
    required this.message,
    required this.button,
    required this.onTap,
  });
  final IconData icon;
  final String title, message, button;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: LayoutBuilder(
          builder: (context, box) {
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpace.xs),
                Text(
                  message,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            );
            final tile = Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, color: scheme.primary),
            );
            final action = OutlinedButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.arrow_forward),
              label: Text(button),
            );
            // Side by side when there is room; stacked on phones and at large
            // text sizes so nothing is squeezed.
            final wide =
                box.maxWidth >= 560 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.3;
            if (wide) {
              return Row(
                children: [
                  tile,
                  const SizedBox(width: AppSpace.md + 2),
                  Expanded(child: text),
                  const SizedBox(width: AppSpace.lg),
                  action,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    tile,
                    const SizedBox(width: AppSpace.md + 2),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                action,
              ],
            );
          },
        ),
      ),
    );
  }
}
