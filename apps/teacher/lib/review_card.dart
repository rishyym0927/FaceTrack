import 'package:facetrack_core/facetrack_core.dart' show AppRadius, AppSpace;
import 'package:flutter/material.dart';

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
  return letters.isEmpty ? '?' : letters;
}

/// A small coloured label with an icon.
class InfoChip extends StatelessWidget {
  const InfoChip(this.icon, this.text, {super.key, this.color});
  final IconData icon;
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: c,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One item waiting for a faculty decision: who, the facts, and the actions.
class ReviewCard extends StatelessWidget {
  const ReviewCard({
    super.key,
    required this.name,
    required this.number,
    required this.chips,
    required this.actions,
    this.body,
  });
  final String name;
  final String? number;
  final List<Widget> chips;
  final Widget? body;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: EdgeInsets.all(narrow ? AppSpace.lg : 18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.primary.withValues(alpha: .10),
                child: Text(
                  initialsOf(name),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (number != null)
                      Text(
                        'Enrolment number: $number',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            Wrap(spacing: 6, runSpacing: 6, children: chips),
          ],
          if (body != null) ...[const SizedBox(height: AppSpace.md), body!],
          const SizedBox(height: AppSpace.lg),
          Wrap(spacing: 10, runSpacing: AppSpace.sm, children: actions),
        ],
      ),
    );
  }
}
