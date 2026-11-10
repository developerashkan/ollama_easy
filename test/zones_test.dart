import 'package:fake_async/fake_async.dart';
import 'package:ollama_easy/ollama_easy.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  // Regression: awaiting a finished subscription's cancel future (a root-zone
  // future) made every request hang inside FakeAsync, so Flutter widget tests
  // using this package never saw a response.
  test('requests and streams complete inside FakeAsync', () {
    fakeAsync((async) {
      final server = FakeServer((request) => request.path.endsWith('version')
          ? jsonResponse({'version': '1'})
          : ndjsonResponse(
              [generateChunk('a'), generateChunk('b', done: true)]));
      final ollama = server.ollama();
      String? version;
      String? text;
      ollama.version().then((v) => version = v);
      String? collected;
      var pulled = false;
      ollama.askStream('x').join().then((v) => text = v);
      ollama.generateStream('x').collect().then((v) => collected = v.response);
      ollama.pull('m').then((_) => pulled = true);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 10));
      expect(version, '1');
      expect(text, 'ab');
      expect(collected, 'ab');
      expect(pulled, isTrue);
      ollama.close();
      async.elapse(const Duration(minutes: 11));
      expect(async.pendingTimers, isEmpty, reason: 'no leaked timeout timers');
    });
  });
}
