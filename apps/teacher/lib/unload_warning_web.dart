import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool _active = false;

/// Whether the leave-site confirmation is currently requested.
bool get unloadWarningActive => _active;

final JSFunction _confirm = ((web.Event event) {
  // Browsers show their own fixed wording; this only requests the prompt.
  event.preventDefault();
  (event as web.BeforeUnloadEvent).returnValue = '';
}).toJS;

/// Turns the browser's leave-site confirmation on or off.
void setUnloadWarning(bool on) {
  if (on == _active) return;
  _active = on;
  if (on) {
    web.window.addEventListener('beforeunload', _confirm);
  } else {
    web.window.removeEventListener('beforeunload', _confirm);
  }
}
