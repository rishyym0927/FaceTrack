import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Attendance details live in the dedicated tab, so Account needs no
/// duplicate dashboard request or potentially stale copy of its numbers.
class TeacherAccountStats extends StatelessWidget {
  const TeacherAccountStats({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.insights_outlined, color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Attendance',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'View published results and students below 75%.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => context.go('/attendance'),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Open attendance'),
          ),
        ],
      ),
    );
  }
}
