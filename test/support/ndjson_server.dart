// A real HTTP server for transport tests, started with spawnHybridUri so it
// runs on the VM even when the test itself runs in a browser.
//
// It is written on raw sockets because dart:io's HttpServer does not report a
// client that disconnects mid-response (writes keep "succeeding"), while a
// socket's read side reliably sees the FIN/RST. That is what the abort tests
// need to observe.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  channel.sink.add(server.port);
  server.listen((socket) => _Connection(socket, channel.sink).run());
  await channel.stream.drain<void>();
  await server.close();
}

const _cors = 'Access-Control-Allow-Origin: *\r\n'
    'Access-Control-Allow-Headers: *\r\n'
    'Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n';

class _Connection {
  _Connection(this.socket, this.events);

  final Socket socket;
  final StreamSink<Object?> events;
  final BytesBuilder _buffer = BytesBuilder();
  bool closed = false;
  bool streaming = false;

  void run() {
    socket.listen(
      (data) {
        _buffer.add(data);
        _drainRequests();
      },
      onDone: _onClosed,
      onError: (_) => _onClosed(),
    );
  }

  void _onClosed() {
    if (closed) return;
    closed = true;
    if (streaming) events.add('aborted');
  }

  void _drainRequests() {
    while (true) {
      final bytes = _buffer.toBytes();
      final headerEnd = _indexOf(bytes, const [13, 10, 13, 10]);
      if (headerEnd == -1) return;
      final head = latin1.decode(bytes.sublist(0, headerEnd));
      final lines = head.split('\r\n');
      final parts = lines.first.split(' ');
      final headers = <String, String>{
        for (final line in lines.skip(1))
          if (line.contains(':'))
            line.substring(0, line.indexOf(':')).trim().toLowerCase():
                line.substring(line.indexOf(':') + 1).trim(),
      };
      final length = int.tryParse(headers['content-length'] ?? '0') ?? 0;
      final total = headerEnd + 4 + length;
      if (bytes.length < total) return;
      _buffer
        ..clear()
        ..add(bytes.sublist(total));
      unawaited(_handle(parts[0], Uri.parse(parts[1])));
    }
  }

  Future<void> _handle(String method, Uri uri) async {
    if (method == 'OPTIONS') {
      socket.write(
          'HTTP/1.1 204 No Content\r\n${_cors}Content-Length: 0\r\n\r\n');
      return;
    }
    socket.write('HTTP/1.1 200 OK\r\n$_cors'
        'Content-Type: application/x-ndjson\r\n'
        'Transfer-Encoding: chunked\r\n\r\n');
    streaming = true;
    final mode = uri.pathSegments.first;
    if (mode == 'stream') {
      // Five chunks, 150 ms apart; the emoji is split across two writes.
      for (var i = 0; i < 4; i++) {
        _chunk(_line('$i '));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      final last = _line('😀', done: true);
      final split = last.indexOf(0xF0) + 2; // inside the 4-byte emoji
      _chunk(last.sublist(0, split));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      _chunk(last.sublist(split));
    } else {
      for (var i = 0; i < 400 && !closed; i++) {
        _chunk(_line('$i '));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      if (!closed) events.add('finished');
    }
    streaming = false;
    if (!closed) socket.write('0\r\n\r\n');
  }

  void _chunk(List<int> bytes) {
    if (closed) return;
    socket
      ..write('${bytes.length.toRadixString(16)}\r\n')
      ..add(bytes)
      ..write('\r\n');
  }

  static List<int> _line(String content, {bool done = false}) =>
      utf8.encode('${jsonEncode({
            'model': 'm',
            'message': {'role': 'assistant', 'content': content},
            'done': done,
          })}\n');

  static int _indexOf(Uint8List bytes, List<int> pattern) {
    outer:
    for (var i = 0; i <= bytes.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
