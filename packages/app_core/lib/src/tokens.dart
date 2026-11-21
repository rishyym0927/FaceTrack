import 'package:flutter/material.dart';

/// Spacing scale (4 px grid). Prefer these over ad-hoc numbers.
class AppSpace {
  const AppSpace._();
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32;
}

/// Corner radii shared by cards, inputs, buttons and chips.
class AppRadius {
  const AppRadius._();
  static const double sm = 8, md = 12, lg = 16, xl = 20, pill = 100;
}

/// Semantic colours. One definition so success/warning/danger read the same on
/// every screen (admin checklists, status pills, attendance percentages).
class AppTone {
  const AppTone._();
  static const success = Color(0xff176451);
  static const warning = Color(0xff9a6a00);
  static const danger = Color(0xffa22f2f);
  static const neutral = Color(0xff587067);
  static const info = Color(0xff1f5f8b);

  /// Soft tinted background for a tone (chips, icon tiles, callouts).
  static Color tint(Color tone, [double alpha = .10]) =>
      tone.withValues(alpha: alpha);
}

/// A small tinted pill: a short label in a semantic tone, optionally with an
/// icon. Use for statuses that are not an API status (see `StatusBadge`).
class TonePill extends StatelessWidget {
  const TonePill(this.label, {super.key, this.tone = AppTone.neutral, this.icon});
  final String label;
  final Color tone;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: AppTone.tint(tone),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: tone),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: tone,
            ),
          ),
        ),
      ],
    ),
  );
}
