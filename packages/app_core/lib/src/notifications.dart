import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'auth.dart';
import 'product_app.dart' show ContentPage;
import 'widgets.dart';

/// How a notice is styled: [action] needs the reader to do something,
/// [warning] is a problem to look at, [success] and [info] are updates.
enum NoticeTone { action, warning, success, info }

/// One in-app notice, derived on the device from existing API data (there is
/// no server-side notification store, push or email). [id] must change when
/// the underlying state changes, so a changed state shows as unread again.
/// [ongoing] notices describe a state that stays listed until it is resolved.
class AppNotice {
  const AppNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.tone,
    required this.icon,
    this.route,
    this.time,
    this.ongoing = false,
  });
  final String id, title, body;
  final NoticeTone tone;
  final IconData icon;
  final String? route;
  final DateTime? time;
  final bool ongoing;
}

class NoticeBatch {
  NoticeBatch(this.items, {this.failed = const [], this.note});
  final List<AppNotice> items;

  /// Names of sources that could not be loaded; the others still show.
  final List<String> failed;
  final String? note;
}

typedef NotificationsLoader = Future<NoticeBatch> Function(
  ApiClient api,
  String institute,
  AuthController auth,
);

/// Collects notices from independent sources: one failing source is reported
/// by name and never hides the others.
class NoticeCollector {
  final items = <AppNotice>[];
  final failed = <String>[];
  Future<void> source(
    String name,
    Future<Iterable<AppNotice>> Function() load,
  ) async {
    try {
      items.addAll(await load());
    } catch (_) {
      failed.add(name);
    }
  }

  NoticeBatch done({String? note}) =>
      NoticeBatch(items, failed: failed, note: note);
}

/// Runs [fetch] over [items] with at most [concurrency] requests in flight.
Future<List<R>> pooled<T, R>(
  List<T> items,
  Future<R> Function(T) fetch, {
  int concurrency = 4,
}) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final i = next++;
      results[i] = await fetch(items[i]);
    }
  }

  await Future.wait([
    for (var w = 0; w < math.min(concurrency, items.length); w++) worker(),
  ]);
  return results.cast<R>();
}

/// Follows a cursor-paged list endpoint up to [maxPages] pages.
Future<List<Json>> fetchAllPages(
  ApiClient api,
  String path,
  String institute, {
  Map<String, dynamic> query = const {},
  int maxPages = 5,
}) async {
  final rows = <Json>[];
  String? cursor;
  var pages = 0;
  do {
    final page = await api.send(
      'GET',
      path,
      institute: institute,
      query: {...query, 'limit': 200, 'cursor': ?cursor},
    );
    rows.addAll(
      (page['items'] as List).map((x) => Map<String, dynamic>.from(x)),
    );
    cursor = page['next_cursor'] as String?;
  } while (cursor != null && ++pages < maxPages);
  return rows;
}

/// Holds the current notices and which ones this user has seen on this
/// device. Refreshes on demand (opening the panel, navigating, app resume),
/// never on a timer.
class NotificationCenter extends ChangeNotifier {
  NotificationCenter(this.loader);
  final NotificationsLoader loader;
  static const maxAge = Duration(minutes: 1);

  List<AppNotice> items = [];
  List<String> failed = [];
  String? note;
  bool loading = false;
  DateTime? loadedAt;
  Set<String> _seen = {};
  String? _key;
  int _generation = 0;

  int get unread => items.where((n) => !_seen.contains(n.id)).length;
  bool isUnread(AppNotice n) => !_seen.contains(n.id);

  String _storageKey(String key) => 'facetrack.notices.$key';

  /// Loads for the signed-in user and institute; a different user or
  /// institute starts from an empty state. Safe to call during build.
  void ensureFresh(ApiClient api, AuthController auth, {bool force = false}) {
    final institute = auth.institute, user = auth.account?.userId;
    if (institute == null || user == null) return;
    final key = '${auth.services.config.roleName}.$user.$institute';
    final stale =
        loadedAt == null || DateTime.now().difference(loadedAt!) > maxAge;
    // Calls in the same frame (shell rebuilds, page open) share one load.
    if (inFlight != null && _inFlightKey == key) {
      if (force) _refreshAfterFlight = true;
      return;
    }
    _refreshAfterFlight = false;
    if (key == _key && !stale && !force) return;
    late final Future<void> run;
    run =
        Future.microtask(
          () => reload(
            key,
            () => force
                ? ApiClient.freshReads(() => loader(api, institute, auth))
                : loader(api, institute, auth),
          ),
        ).whenComplete(() {
          if (!identical(inFlight, run)) return;
          inFlight = null;
          if (_refreshAfterFlight &&
              auth.institute == institute &&
              auth.account?.userId == user) {
            ensureFresh(api, auth, force: true);
          }
        });
    inFlight = run;
    _inFlightKey = key;
  }

  String? _inFlightKey;
  bool _refreshAfterFlight = false;

  /// The load in progress, if any; completes when the list is replaced.
  Future<void>? inFlight;

  /// Replaces the notices with [fetch]'s result for the account [key].
  Future<void> reload(String key, Future<NoticeBatch> Function() fetch) async {
    final generation = ++_generation;
    if (key != _key) {
      _key = key;
      items = [];
      failed = [];
      note = null;
      loadedAt = null;
      _seen = await _readSeen(key);
    }
    loading = true;
    notifyListeners();
    NoticeBatch batch;
    try {
      batch = await fetch();
    } catch (_) {
      batch = NoticeBatch(const [], failed: const ['notifications']);
    }
    if (generation != _generation) return;
    items = sortNotices(batch.items);
    failed = batch.failed;
    note = batch.note;
    loading = false;
    loadedAt = DateTime.now();
    // Forget ids that no longer exist so the stored set cannot grow forever.
    _seen = _seen.intersection({for (final n in items) n.id});
    await _writeSeen();
    notifyListeners();
  }

  Future<void> markRead(AppNotice n) async {
    if (_seen.add(n.id)) {
      notifyListeners();
      await _writeSeen();
    }
  }

  Future<void> markAllRead() async {
    _seen.addAll(items.map((n) => n.id));
    notifyListeners();
    await _writeSeen();
  }

  Future<Set<String>> _readSeen(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _storageKey(key),
      );
      return raw == null ? {} : {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeSeen() async {
    final key = _key;
    if (key == null) return;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _storageKey(key),
        jsonEncode(_seen.toList()),
      );
    } catch (_) {
      // Read state is a convenience; the list still works without it.
    }
  }
}

/// Actions first, then warnings, then updates; newest first inside each.
List<AppNotice> sortNotices(List<AppNotice> items) {
  final sorted = [...items];
  sorted.sort((a, b) {
    final tone = a.tone.index.compareTo(b.tone.index);
    if (tone != 0) return tone;
    final at = a.time, bt = b.time;
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  });
  return sorted;
}

String noticeAge(DateTime time, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(time);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  final l = time.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, required this.center});
  final NotificationCenter center;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: center,
    builder: (context, _) {
      final n = center.unread;
      return IconButton(
        tooltip: n == 0 ? 'Notifications' : 'Notifications, $n unread',
        onPressed: () => context.go('/notifications'),
        icon: Badge(
          isLabelVisible: n > 0,
          label: Text(n > 99 ? '99+' : '$n'),
          child: Icon(
            n > 0
                ? Icons.notifications_active_outlined
                : Icons.notifications_none,
          ),
        ),
      );
    },
  );
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({
    super.key,
    required this.center,
    required this.refresh,
  });
  final NotificationCenter center;
  final VoidCallback refresh;
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool unreadOnly = false;

  @override
  void initState() {
    super.initState();
    widget.refresh();
  }

  /// Starts a forced reload and completes once the list has been replaced.
  Future<void> _pullRefresh() async {
    widget.refresh();
    try {
      // The refresh, or a load already running, replaces the list.
      await widget.center.inFlight?.timeout(const Duration(seconds: 20));
    } catch (_) {
      // A slow network still releases the indicator.
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.center,
    builder: (context, _) {
      final c = widget.center, scheme = Theme.of(context).colorScheme;
      final shown = [
        for (final n in c.items)
          if (!unreadOnly || c.isUnread(n)) n,
      ];
      final actions = [
        for (final n in shown)
          if (n.tone == NoticeTone.action || n.tone == NoticeTone.warning) n,
      ];
      final updates = [
        for (final n in shown)
          if (n.tone == NoticeTone.success || n.tone == NoticeTone.info) n,
      ];
      return ContentPage(
        onRefresh: _pullRefresh,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notifications',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.unread == 0
                        ? 'You are all caught up.'
                        : '${c.unread} unread',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Unread only'),
                    selected: unreadOnly,
                    onSelected: (v) => setState(() => unreadOnly = v),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.unread == 0 ? null : c.markAllRead,
                    icon: const Icon(Icons.done_all),
                    label: const Text('Mark all as read'),
                  ),
                  IconButton(
                    tooltip: 'Refresh notifications',
                    onPressed: c.loading ? null : widget.refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (c.loading) const LinearProgressIndicator(),
          if (c.failed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Note(
                icon: Icons.cloud_off_outlined,
                text:
                    'Some updates could not be loaded (${c.failed.join(', ')}). Use refresh to try again.',
              ),
            ),
          if (c.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Note(icon: Icons.info_outline, text: c.note!),
            ),
          if (!c.loading && shown.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: MessageView(
                title: unreadOnly ? 'No unread notifications' : 'Nothing new',
                message: 'Approvals, published attendance and items that need your attention appear here.',
              ),
            ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 20),
            _Heading('Needs attention', actions.length),
            for (final n in actions) _NoticeTile(center: c, notice: n),
          ],
          for (final (label, group) in groupByDay(updates)) ...[
            const SizedBox(height: 20),
            _Heading(label, group.length),
            for (final n in group) _NoticeTile(center: c, notice: n),
          ],
          const SizedBox(height: 20),
          Text(
            'Notifications are shown inside the app only. Read status is remembered on this device.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      );
    },
  );
}

/// Updates by when they happened: Today, Yesterday, This week, Earlier;
/// undated updates (current states) come first as "Current".
List<(String, List<AppNotice>)> groupByDay(
  List<AppNotice> items, {
  DateTime? now,
}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  String label(AppNotice n) {
    final t = n.time;
    if (t == null) return 'Current';
    final days = today.difference(DateUtils.dateOnly(t.toLocal())).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return 'This week';
    return 'Earlier';
  }

  const order = ['Current', 'Today', 'Yesterday', 'This week', 'Earlier'];
  final groups = <String, List<AppNotice>>{};
  for (final n in items) {
    groups.putIfAbsent(label(n), () => []).add(n);
  }
  return [
    for (final k in order)
      if (groups[k] != null) (k, groups[k]!),
  ];
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, this.count);
  final String text;
  final int count;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      '$text · $count',
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({required this.center, required this.notice});
  final NotificationCenter center;
  final AppNotice notice;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = center.isUnread(notice);
    final (Color fg, Color bg) = switch (notice.tone) {
      NoticeTone.action => (
        scheme.primary,
        scheme.primary.withValues(alpha: .1),
      ),
      NoticeTone.warning => (const Color(0xffa15c07), const Color(0xfffff1db)),
      NoticeTone.success => (const Color(0xff1d7a4f), const Color(0xffe3f4ea)),
      NoticeTone.info => (
        scheme.onSurfaceVariant,
        scheme.surfaceContainerLowest,
      ),
    };
    final route = notice.route;
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: unread ? Colors.white : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: unread ? fg.withValues(alpha: .35) : scheme.outline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            center.markRead(notice);
            // Push, so back returns to the notifications.
            if (route != null) context.push(route);
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(notice.icon, color: fg, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notice.title,
                        style: TextStyle(
                          fontWeight: unread
                              ? FontWeight.w800
                              : FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        notice.body,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      if (notice.time != null || notice.ongoing) ...[
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (notice.time != null) noticeAge(notice.time!),
                            if (notice.ongoing) 'Stays here until resolved',
                          ].join(' · '),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (unread)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 6),
                    child: Semantics(
                      label: 'Unread',
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: fg,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                if (route != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!unread) return tile;
    // Swipe sideways to mark as read; the notice stays in the list.
    return Dismissible(
      key: ValueKey('notice:${notice.id}'),
      confirmDismiss: (_) async {
        await center.markRead(notice);
        return false;
      },
      background: _SwipeHint(alignment: Alignment.centerLeft),
      secondaryBackground: _SwipeHint(alignment: Alignment.centerRight),
      child: tile,
    );
  }
}

class _SwipeHint extends StatelessWidget {
  const _SwipeHint({required this.alignment});
  final Alignment alignment;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    alignment: alignment,
    decoration: BoxDecoration(
      color: const Color(0xffe3f4ea),
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.done, color: Color(0xff1d7a4f)),
        SizedBox(width: 6),
        Text(
          'Mark as read',
          style: TextStyle(
            color: Color(0xff1d7a4f),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}
