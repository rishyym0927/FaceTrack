import 'package:flutter/material.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'api.dart';

ThemeData appTheme() {
  const primary = Color(0xff176451),
      ink = Color(0xff172d27),
      border = Color(0xffdfe6e2);
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ).copyWith(primary: primary, surface: Colors.white, onSurface: ink),
    scaffoldBackgroundColor: const Color(0xfff5f7f5),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.all(16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    visualDensity: VisualDensity.standard,
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = 24});
  final Widget child;
  final double padding;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final String title, subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: LayoutBuilder(
      builder: (context, c) {
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
          ],
        );
        if (c.maxWidth < 600)
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: text),
            if (action != null) action!,
          ],
        );
      },
    ),
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'active' => const Color(0xff176451),
      'requested' => const Color(0xff805500),
      'rejected' => const Color(0xffa22f2f),
      _ => const Color(0xff465650),
    };
    return Semantics(
      label: 'Status: ' + statusLabel(status),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          statusLabel(status),
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.title,
    required this.message,
    this.action,
    this.icon = Icons.info_outline,
  });
  final String title, message;
  final Widget? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    ),
  );
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => MessageView(
    title:
        error is AppFailure &&
            (error as AppFailure).code == 'development_api_unreachable'
        ? 'Mac connection unavailable'
        : error is AppFailure && (error as AppFailure).status == 403
        ? 'Access unavailable'
        : 'Could not load this page',
    message: error is AppFailure
        ? (error as AppFailure).message
        : 'Please retry. If this continues, contact your institute.',
    action: OutlinedButton.icon(
      onPressed: retry,
      icon: const Icon(Icons.refresh),
      label: const Text('Retry'),
    ),
    icon: Icons.cloud_off_outlined,
  );
}

class PagedController<T> extends ChangeNotifier {
  PagedController(this.fetch);
  final Future<PageData<T>> Function(String?) fetch;
  List<T> items = [];
  String? cursor;
  Object? error;
  bool loading = false, _disposed = false;
  int _generation = 0;
  bool _retryReset = true;
  Future<void> retry() => load(reset: _retryReset);
  Future<void> load({bool reset = true}) async {
    if (loading && !reset) return;
    _retryReset = reset;
    final generation = ++_generation;
    if (reset) {
      cursor = null;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final data = await fetch(cursor);
      if (_disposed || generation != _generation) return;
      items = reset ? data.items : [...items, ...data.items];
      cursor = data.nextCursor;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e;
      if (e is AppFailure && [401, 403, 404].contains(e.status)) items = [];
    }
    if (_disposed || generation != _generation) return;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}

class PagedList<T> extends StatelessWidget {
  const PagedList({
    super.key,
    required this.controller,
    required this.item,
    required this.emptyTitle,
    required this.emptyMessage,
  });
  final PagedController<T> controller;
  final Widget Function(T) item;
  final String emptyTitle, emptyMessage;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.loading && controller.items.isEmpty)
        return const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: CircularProgressIndicator()),
        );
      if (controller.error != null && controller.items.isEmpty)
        return ErrorView(controller.error!, retry: () => controller.load());
      if (controller.items.isEmpty)
        return MessageView(
          title: emptyTitle,
          message: emptyMessage,
          icon: Icons.groups_outlined,
        );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.loading) const LinearProgressIndicator(),
          for (final value in controller.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: item(value),
            ),
          if (controller.error != null)
            ErrorView(controller.error!, retry: () => controller.retry()),
          if (controller.cursor != null)
            Align(
              alignment: Alignment.center,
              child: OutlinedButton(
                onPressed: controller.loading
                    ? null
                    : () => controller.load(reset: false),
                child: const Text('Load more'),
              ),
            ),
        ],
      );
    },
  );
}

class ActionDialog extends StatefulWidget {
  const ActionDialog({
    super.key,
    required this.title,
    required this.child,
    required this.submit,
    this.button = 'Confirm',
  });
  final String title, button;
  final Widget child;
  final Future<void> Function(Mutation) submit;
  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  final form = GlobalKey<FormState>();
  final mutation = Mutation();
  bool busy = false;
  String? error;
  Future<void> save() async {
    if (busy) return;
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.submit(mutation);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      if (e is AppFailure && e.status == 409) {
        Navigator.of(context).pop(false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      } else {
        setState(
          () => error = e is AppFailure
              ? e.message
              : 'Could not save. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.child,
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'Saving…' : widget.button),
        ),
      ],
    ),
  );
}

String? requiredText(String? value) =>
    (value == null || value.trim().isEmpty) ? 'This field is required.' : null;
void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
