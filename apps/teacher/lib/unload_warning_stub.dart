bool _active = false;

/// Whether the leave-site confirmation is currently requested (the browser build uses the same flag).
bool get unloadWarningActive => _active;

/// Turns the browser's leave-site confirmation on or off. A no-op outside the browser.
void setUnloadWarning(bool on) => _active = on;
