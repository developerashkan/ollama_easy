// End-to-end transport tests over real sockets, with the platform's default
// http client: IOClient on the VM, the fetch-based BrowserClient on the web.
//
//   dart test test/real_transport_test.dart              # VM
//   dart test -p chrome test/real_transport_test.dart    # browser (fetch)
import 'dart:async';

import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

void main() {
  late StreamChannelLike server;

  setUpAll(() async {
    final channel = spawnHybridUri('support/ndjson_server.dart');
    final events = StreamIterator(channel.stream);
    await events.moveNext();
    server =
        StreamChannelLike(events.current! as int, events, channel.sink.close);
  });

  tearDownAll(() => server.close());

  test('chunks arrive incrementally (real streaming, not buffered)', () async {
    final ollama =
        Ollama(baseUrl: Uri.parse('http://127.0.0.1:${server.port}/stream'));
    final stopwatch = Stopwatch()..start();
    final arrivals = <Duration>[];
    final text = StringBuffer();
    await for (final delta
        in ollama.chatTextStream([const OllamaMessage.user('x')])) {
      arrivals.add(stopwatch.elapsed);
      text.write(delta);
    }
    expect(text.toString(), '0 1 2 3 😀');
    expect(arrivals, hasLength(5));
    // The first chunk must arrive long before the last one was sent.
    expect(arrivals.last - arrivals.first,
        greaterThan(const Duration(milliseconds: 400)));
    ollama.close();
  });

  test('cancelling a real stream closes the connection on the server',
      () async {
    final ollama =
        Ollama(baseUrl: Uri.parse('http://127.0.0.1:${server.port}/endless'));
    final token = OllamaCancelToken();
    var chunks = 0;
    await expectLater(
      ollama.chatTextStream([const OllamaMessage.user('x')],
          cancelToken: token).forEach((_) {
        if (++chunks == 3) token.cancel();
      }),
      throwsA(isA<OllamaCancelledException>()),
    );
    expect(chunks, 3);
    expect(await server.next().timeout(const Duration(seconds: 10)), 'aborted');
    ollama.close();
  });

  test('breaking out of the loop also closes the connection', () async {
    final ollama =
        Ollama(baseUrl: Uri.parse('http://127.0.0.1:${server.port}/endless'));
    await for (final _
        in ollama.chatTextStream([const OllamaMessage.user('x')])) {
      break;
    }
    expect(await server.next().timeout(const Duration(seconds: 10)), 'aborted');
    ollama.close();
  });
}

class StreamChannelLike {
  StreamChannelLike(this.port, this._events, this._close);

  final int port;
  final StreamIterator<Object?> _events;
  final Future<void> Function() _close;

  Future<Object?> next() async {
    if (!await _events.moveNext()) return null;
    return _events.current;
  }

  Future<void> close() => _close();
}
