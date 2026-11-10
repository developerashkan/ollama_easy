import 'dart:async';

import 'cancel_token.dart';
import 'exceptions.dart';
import 'models.dart';

/// The outcome of one tool call made by `runTools`.
class OllamaToolInvocation {
  const OllamaToolInvocation({
    required this.call,
    required this.message,
    required this.elapsed,
    this.result,
    this.error,
  });

  final OllamaToolCall call;

  /// What the handler returned (null on error).
  final Object? result;

  /// What the handler threw, or why it could not run.
  final Object? error;

  /// The `tool` message sent back to the model.
  final OllamaMessage message;
  final Duration elapsed;

  bool get succeeded => error == null;
}

/// The result of `runTools`.
class OllamaToolRun {
  const OllamaToolRun({
    required this.response,
    required this.messages,
    required this.invocations,
    required this.iterations,
  });

  /// The final model response (no more tool calls).
  final OllamaChatResponse response;

  /// The whole conversation: your messages, every assistant tool call, every
  /// tool result and the final answer. Feed it back in to continue.
  final List<OllamaMessage> messages;

  /// Every tool call that was executed, in order.
  final List<OllamaToolInvocation> invocations;

  /// Number of chat requests made.
  final int iterations;

  /// The final answer text.
  String get text => response.text;
}

/// Events from `runToolsStream`.
sealed class OllamaToolRunEvent {
  const OllamaToolRunEvent();
}

/// A piece of the model's answer.
class OllamaToolRunTextDelta extends OllamaToolRunEvent {
  const OllamaToolRunTextDelta(this.text);
  final String text;
}

/// A piece of the model's reasoning.
class OllamaToolRunThinkingDelta extends OllamaToolRunEvent {
  const OllamaToolRunThinkingDelta(this.text);
  final String text;
}

/// The model asked to call a tool; it is about to run.
class OllamaToolRunCallStarted extends OllamaToolRunEvent {
  const OllamaToolRunCallStarted(this.call);
  final OllamaToolCall call;
}

/// A tool finished (successfully or not).
class OllamaToolRunCallFinished extends OllamaToolRunEvent {
  const OllamaToolRunCallFinished(this.invocation);
  final OllamaToolInvocation invocation;
}

/// The loop finished. Always the last event.
class OllamaToolRunDone extends OllamaToolRunEvent {
  const OllamaToolRunDone(this.run);
  final OllamaToolRun run;
}

/// Decides whether a tool call may run. Return `false` to refuse it; the
/// model is told the call was denied.
typedef OllamaToolApproval = FutureOr<bool> Function(OllamaToolCall call);

/// Turns a handler error into the text sent to the model.
typedef OllamaToolErrorFormatter = String Function(
    OllamaToolCall call, Object error);

/// Executes [calls] against [tools]. Internal helper shared by the client and
/// the conversation.
Future<List<OllamaToolInvocation>> executeToolCalls(
  List<OllamaToolCall> calls,
  Map<String, OllamaTool> tools, {
  bool parallel = true,
  bool rethrowErrors = false,
  OllamaToolApproval? approve,
  OllamaToolErrorFormatter? formatError,
  OllamaCancelToken? cancelToken,
  void Function(OllamaToolCall call)? onStart,
  void Function(OllamaToolInvocation invocation)? onFinish,
}) async {
  Future<OllamaToolInvocation> run(OllamaToolCall call) async {
    cancelToken?.throwIfCancelled();
    onStart?.call(call);
    final stopwatch = Stopwatch()..start();
    OllamaToolInvocation done({Object? result, Object? error, String? text}) {
      final invocation = OllamaToolInvocation(
        call: call,
        result: result,
        error: error,
        elapsed: stopwatch.elapsed,
        message: OllamaMessage.tool(
          text ?? encodeToolResult(result),
          toolName: call.name,
          toolCallId: call.id,
        ),
      );
      onFinish?.call(invocation);
      return invocation;
    }

    final tool = tools[call.name];
    final handler = tool?.handler;
    if (tool == null || handler == null) {
      final reason = tool == null
          ? 'Error: unknown tool "${call.name}". '
              'Available tools: ${tools.keys.join(', ')}.'
          : 'Error: tool "${call.name}" has no handler.';
      return done(error: StateError(reason), text: reason);
    }
    if (approve != null && !await approve(call)) {
      const text = 'Error: the user denied this tool call.';
      return done(error: StateError(text), text: text);
    }
    try {
      final result = await handler(call.arguments);
      return done(result: result);
    } catch (error) {
      if (rethrowErrors || error is OllamaCancelledException) rethrow;
      final text = formatError?.call(call, error) ?? 'Error: $error';
      return done(error: error, text: text);
    }
  }

  if (parallel && calls.length > 1) {
    return Future.wait([for (final call in calls) run(call)]);
  }
  final results = <OllamaToolInvocation>[];
  for (final call in calls) {
    results.add(await run(call));
  }
  return results;
}
