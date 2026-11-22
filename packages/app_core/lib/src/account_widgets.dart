import 'package:flutter/material.dart';

import 'brand.dart';
import 'tokens.dart';

/// Gradient banner at the top of the Account page: avatar with initials, the
/// person's name, their institute and one pill per active role.
///
/// Side by side on most screens; the avatar sits above the text on very
/// narrow screens or at large text sizes so nothing is squeezed.
class AccountHeader extends StatelessWidget {
  const AccountHeader({
    super.key,
    required this.name,
    required this.initials,
    required this.roles,
    this.institute,
  });
  final String name, initials;
  final String? institute;
  final List<String> roles;

  @override
  Widget build(BuildContext context) {
    final avatar = ExcludeSemantics(
      child: CircleAvatar(
        radius: 32,
        backgroundColor: Colors.white,
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Brand.green,
          ),
        ),
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -.5,
              height: 1.15,
            ),
          ),
        ),
        if (institute != null && institute!.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.account_balance_outlined,
                  size: 16,
                  color: Brand.mint,
                ),
              ),
              const SizedBox(width: AppSpace.sm - 2),
              Expanded(
                child: Text(
                  institute!,
                  style: const TextStyle(color: Brand.mint, height: 1.3),
                ),
              ),
            ],
          ),
        ],
        if (roles.isNotEmpty) ...[
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [for (final role in roles) _RolePill(role)],
          ),
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.all(AppSpace.xl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: Brand.gradient,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final stacked =
              box.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [avatar, const SizedBox(height: AppSpace.md), text],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatar,
              const SizedBox(width: AppSpace.lg),
              Expanded(child: text),
            ],
          );
        },
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0x26ffffff),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.badge_outlined, size: 15, color: Colors.white),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

/// Small uppercase heading that names a group of account cards.
class AccountGroupLabel extends StatelessWidget {
  const AccountGroupLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.xs,
      AppSpace.xl,
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

/// One tappable row in an account card: icon tile, title, optional detail,
/// and a chevron.
class AccountActionRow extends StatelessWidget {
  const AccountActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.detail,
  });
  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(width: AppSpace.md + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  if (detail != null && detail!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// The sign-out control: clearly destructive (danger colour and border) but
/// not filled, so it never competes with the page's real actions.
class SignOutButton extends StatelessWidget {
  const SignOutButton({super.key, required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: const Icon(Icons.logout),
    label: const Text('Sign out'),
    style: OutlinedButton.styleFrom(
      foregroundColor: AppTone.danger,
      minimumSize: const Size.fromHeight(52),
      side: BorderSide(color: AppTone.danger.withValues(alpha: .45)),
      backgroundColor: AppTone.tint(AppTone.danger, .04),
    ),
  );
}
