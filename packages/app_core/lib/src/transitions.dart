import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// One motion system for both apps: sibling pages (tabs) fade through each
/// other, a detail page slides in from the right and back reverses it.
/// Reduced motion shows every page instantly.

const _fadeIn = Duration(milliseconds: 260),
    _fadeOut = Duration(milliseconds: 200);
const _slideIn = Duration(milliseconds: 300),
    _slideOut = Duration(milliseconds: 250);

/// Old page fades out during the first third; the new one fades in and
/// settles from 98% scale, so the two never fight for attention.
Widget fadeThrough(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final incoming = CurvedAnimation(
    parent: animation,
    curve: const Interval(.3, 1, curve: Curves.easeOutCubic),
    reverseCurve: const Interval(.3, 1, curve: Curves.easeInCubic),
  );
  final outgoing = CurvedAnimation(
    parent: secondaryAnimation,
    curve: const Interval(0, .35, curve: Curves.easeInCubic),
  );
  return FadeTransition(
    opacity: ReverseAnimation(outgoing),
    child: FadeTransition(
      opacity: incoming,
      child: ScaleTransition(
        scale: Tween(begin: .98, end: 1.0).animate(incoming),
        child: child,
      ),
    ),
  );
}

/// Shared horizontal axis: the new page arrives from the right while the one
/// underneath drifts left and dims; popping plays it backwards.
Widget slideThrough(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final enter = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final under = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return SlideTransition(
    position: Tween(
      begin: Offset.zero,
      end: const Offset(-.03, 0),
    ).animate(under),
    child: FadeTransition(
      opacity: Tween(begin: 1.0, end: .6).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: const Interval(0, .6),
        ),
      ),
      child: SlideTransition(
        position: Tween(
          begin: const Offset(.06, 0),
          end: Offset.zero,
        ).animate(enter),
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0, .7),
          ),
          child: child,
        ),
      ),
    ),
  );
}

/// A top-level page (a tab, or an auth screen).
Page<void> fadeThroughPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: _fadeIn,
      reverseTransitionDuration: _fadeOut,
      transitionsBuilder: fadeThrough,
    );

/// A detail page opened from a list or another page.
Page<void> slidePage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: _slideIn,
      reverseTransitionDuration: _slideOut,
      transitionsBuilder: slideThrough,
    );

/// The theme default for any page not built by the router helpers above, on
/// every platform (web otherwise uses the host's slide, Android a zoom).
class AppPageTransitions extends PageTransitionsBuilder {
  const AppPageTransitions();
  @override
  Duration get transitionDuration => _fadeIn;
  @override
  Duration get reverseTransitionDuration => _fadeOut;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => fadeThrough(context, animation, secondaryAnimation, child);
}

/// Back to where the user came from when there is such a page, otherwise to
/// [fallback] (a deep link or a refreshed tab has nothing to pop to).
void goBack(BuildContext context, String fallback) =>
    context.canPop() ? context.pop() : context.go(fallback);
