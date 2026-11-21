// Asks the browser to confirm before the tab is closed or reloaded while unsaved attendance
// decisions exist. The in-app exit guard only sees navigation inside the app; a reload, the
// browser Back button leaving the site or closing the tab would otherwise drop the choices
// silently. Does nothing on phones.
export 'unload_warning_stub.dart'
    if (dart.library.js_interop) 'unload_warning_web.dart';
