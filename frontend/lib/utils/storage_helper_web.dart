import 'dart:html' as html;

Future<void> setLocalStorageValue(String key, String value) async {
  html.window.localStorage[key] = value;
}

Future<String?> getLocalStorageValue(String key) async {
  return html.window.localStorage[key];
}

Future<void> removeLocalStorageValue(String key) async {
  html.window.localStorage.remove(key);
}
