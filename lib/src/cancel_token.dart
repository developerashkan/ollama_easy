import 'dart:async';

import 'exceptions.dart';

/// Cancels one or more in-flight requests.
///
/// Pass the same token to any number of calls; [cancel] aborts all of them.
/// Aborting closes the HTTP connection, which also makes Ollama stop
/// generating.
///
/// ```dart
/// final token = OllamaCancelToken();
/// final stream = ollama.chatStream(messages, cancelToken: token);
/// stopButton.onPressed = token.cancel;
/// ```
///
/// A cancelled request fails with [OllamaCancelledException]. Streams emit
/// that exception and then close. Simply cancelling your stream subscription
/// (`break` in an `await for`) also aborts the request; no token is needed for
/// that.
class OllamaCancelToken {
  OllamaCancelToken();

  /// A token that is cancelled as soon as any of [tokens] is cancelled.
  factory OllamaCancelToken.any(Iterable<OllamaCancelToken?> tokens) {
    final combined = OllamaCancelToken();
    for (final token in tokens) {
      token?.addListener(() => combined.cancel(token.reason));
    }
    return combined;
  }

  /// A token that cancels itself after [duration].
  factory OllamaCancelToken.after(Duration duration) {
    final token = OllamaCancelToken();
    final timer =
        Timer(duration, () => token.cancel('timeout after $duration'));
    token.addListener(timer.cancel);
    return token;
  }

  final List<void Function()> _listeners = [];
  bool _cancelled = false;
  Object? _reason;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// The reason passed to [cancel].
  Object? get reason => _reason;

  /// Cancels every request that uses this token. Safe to call more than once.
  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Completes when the token is cancelled.
  Future<void> get whenCancelled {
    if (_cancelled) return Future.value();
    final completer = Completer<void>();
    addListener(completer.complete);
    return completer.future;
  }

  /// Runs [listener] once when the token is cancelled (immediately if it
  /// already is). Returns a function that removes the listener.
  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Throws [OllamaCancelledException] if the token is cancelled.
  void throwIfCancelled() {
    if (_cancelled) {
      throw OllamaCancelledException('Request cancelled.', reason: _reason);
    }
  }
}
