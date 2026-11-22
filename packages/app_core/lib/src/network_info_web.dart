import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Coarse connection details from `navigator.connection` and `navigator.onLine`: no permission,
/// no identifiers (never the network's name). Chrome and Edge provide the details; other
/// browsers give only the online flag. Returns only values from the server's fixed vocabulary.
Map<String, Object> networkContext() {
  final out = <String, Object>{};
  try {
    final navigator = globalContext.getProperty<JSAny?>('navigator'.toJS);
    if (navigator is! JSObject) return out;
    if (navigator.getProperty<JSAny?>('onLine'.toJS).dartify() == false) {
      out['network'] = 'offline';
    }
    final connection = navigator.getProperty<JSAny?>('connection'.toJS);
    if (connection is! JSObject) return out;
    final type = connection.getProperty<JSAny?>('type'.toJS).dartify();
    if (!out.containsKey('network')) {
      out['network'] = switch (type) {
        'wifi' || 'cellular' || 'ethernet' => type as String,
        'none' => 'offline',
        _ => 'unknown',
      };
    }
    final effective = connection.getProperty<JSAny?>('effectiveType'.toJS).dartify();
    if (effective is String && const {'slow-2g', '2g', '3g', '4g'}.contains(effective)) {
      out['net_class'] = effective;
    }
    final downlink = connection.getProperty<JSAny?>('downlink'.toJS).dartify();
    if (downlink is num && downlink.isFinite && downlink >= 0) {
      out['downlink_mbps'] = double.parse(downlink.toStringAsFixed(2));
    }
    final rtt = connection.getProperty<JSAny?>('rtt'.toJS).dartify();
    if (rtt is num && rtt.isFinite && rtt >= 0) out['rtt_ms'] = rtt.round();
  } catch (_) {
    // Diagnostics must never break the app.
  }
  return out;
}
