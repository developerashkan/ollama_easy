// A streaming chat app for Ollama, built with ollama_easy.
//
// Shows: model list, connection status, token streaming with a stop button
// (cancel token), thinking models, history trimming and per-reply speed.
//
// Android emulator: the host machine is 10.0.2.2. Web: start Ollama with
// OLLAMA_ORIGINS="*" so the browser may call it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ollama_easy/ollama_easy.dart';

void main() => runApp(ChatApp(ollama: Ollama(host: _defaultHost)));

String get _defaultHost =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2:11434'
        : 'localhost:11434';

class ChatApp extends StatefulWidget {
  const ChatApp({super.key, required this.ollama, this.themeMode});

  final Ollama ollama;
  final ThemeMode? themeMode;

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  late final ChatController controller = ChatController(widget.ollama)
    ..connect();

  @override
  void dispose() {
    controller.dispose();
    widget.ollama.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF3B6EF5), brightness: brightness),
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'Ollama chat',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: widget.themeMode ?? ThemeMode.system,
      home: ChatScreen(controller: controller),
    );
  }
}

// -----------------------------------------------------------------------------
// State

enum ServerStatus { checking, online, offline }

class ChatEntry {
  ChatEntry.user(this.text)
      : isUser = true,
        streaming = false;
  ChatEntry.assistant()
      : isUser = false,
        text = '',
        streaming = true;

  final bool isUser;
  String text;
  String thinking = '';
  bool streaming;
  bool stopped = false;
  String? error;
  String? stats;
}

class ChatController extends ChangeNotifier {
  ChatController(this.ollama);

  final Ollama ollama;
  ServerStatus status = ServerStatus.checking;
  List<String> models = const [];
  String? model;
  bool think = false;
  final List<ChatEntry> entries = [];
  late final OllamaConversation _conversation =
      ollama.conversation(maxMessages: 40);
  OllamaCancelToken? _token;

  bool get isStreaming => _token != null;

  Future<void> connect() async {
    status = ServerStatus.checking;
    notifyListeners();
    try {
      final installed = await ollama.models();
      models = [
        for (final m in installed)
          if (!m.name.contains('embed')) m.name,
      ];
      model ??= models.isEmpty ? null : models.first;
      status = ServerStatus.online;
    } on OllamaException {
      status = ServerStatus.offline;
    }
    notifyListeners();
  }

  void selectModel(String value) {
    model = value;
    notifyListeners();
  }

  void toggleThink() {
    think = !think;
    notifyListeners();
  }

  void clear() {
    stop();
    entries.clear();
    _conversation.clear();
    notifyListeners();
  }

  void stop() => _token?.cancel();

  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || isStreaming || model == null) return;
    final reply = ChatEntry.assistant();
    entries
      ..add(ChatEntry.user(prompt))
      ..add(reply);
    _conversation.add(OllamaMessage.user(prompt));
    final token = _token = OllamaCancelToken();
    notifyListeners();

    final accumulator = OllamaChatAccumulator();
    try {
      await for (final chunk in ollama.chatStream(
        _conversation.messages,
        model: model,
        think: think ? true : null,
        cancelToken: token,
      )) {
        accumulator.add(chunk);
        reply
          ..text = accumulator.content
          ..thinking = accumulator.thinking;
        notifyListeners();
      }
      final done = accumulator.response;
      final speed = done.tokensPerSecond;
      reply.stats = [
        if (done.evalCount != null) '${done.evalCount} tokens',
        if (speed != null) '${speed.toStringAsFixed(1)} tok/s',
      ].join(' · ');
    } on OllamaCancelledException {
      reply.stopped = true;
    } on OllamaException catch (error) {
      reply.error = error is OllamaNotFoundException
          ? '${error.message}. Pull it with: ollama pull $model'
          : error.message;
      if (error is OllamaConnectionException) status = ServerStatus.offline;
    } finally {
      if (accumulator.content.isNotEmpty) {
        _conversation.add(accumulator.message);
      }
      reply.streaming = false;
      _token = null;
      notifyListeners();
    }
  }
}

// -----------------------------------------------------------------------------
// UI

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _submit([String? text]) {
    final value = text ?? _input.text;
    if (value.trim().isEmpty) return;
    _input.clear();
    c.send(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            _StatusDot(status: c.status),
            const SizedBox(width: 10),
            Expanded(child: _ModelPicker(controller: c)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: c.think ? 'Thinking on' : 'Thinking off',
            isSelected: c.think,
            onPressed: c.toggleThink,
            icon: const Icon(Icons.lightbulb_outline),
            selectedIcon: Icon(Icons.lightbulb, color: scheme.tertiary),
          ),
          IconButton(
            tooltip: 'New chat',
            onPressed: c.entries.isEmpty ? null : c.clear,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (c.status == ServerStatus.offline)
            MaterialBanner(
              leading: const Icon(Icons.cloud_off),
              content: Text("Can't reach Ollama at ${c.ollama.baseUrl}. "
                  'Is `ollama serve` running?'),
              actions: [
                TextButton(onPressed: c.connect, child: const Text('RETRY'))
              ],
            ),
          Expanded(
            child: c.entries.isEmpty
                ? _EmptyState(onPick: _submit)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    itemCount: c.entries.length,
                    itemBuilder: (context, i) => _Bubble(entry: c.entries[i]),
                  ),
          ),
          _Composer(
            controller: _input,
            streaming: c.isStreaming,
            enabled: c.model != null,
            onSend: _submit,
            onStop: c.stop,
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final ServerStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ServerStatus.online => const Color(0xFF2EB67D),
      ServerStatus.offline => Theme.of(context).colorScheme.error,
      ServerStatus.checking => Colors.amber,
    };
    return Tooltip(
      message: status.name,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (controller.models.isEmpty) {
      return Text(
        controller.status == ServerStatus.online
            ? 'No models installed'
            : 'Ollama',
        style: text.titleMedium,
      );
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: controller.model,
        isExpanded: true,
        style: text.titleMedium,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final m in controller.models)
            DropdownMenuItem(
                value: m, child: Text(m, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: controller.isStreaming
            ? null
            : (value) => controller.selectModel(value!),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final ValueChanged<String> onPick;

  static const _ideas = [
    'Explain Dart streams like I am five',
    'Write a haiku about local AI',
    'Plan a 3-day trip to Lisbon',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined,
                size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('Chat with a local model', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Private, offline, streaming.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final idea in _ideas)
                  ActionChip(label: Text(idea), onPressed: () => onPick(idea)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = entry.isUser;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: user ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(user ? 18 : 4),
              bottomRight: Radius.circular(user ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.thinking.isNotEmpty) _Thinking(text: entry.thinking),
              if (entry.text.isNotEmpty || entry.streaming)
                Text.rich(
                  TextSpan(
                    text: entry.text,
                    children: [
                      if (entry.streaming)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Container(
                            width: 9,
                            height: 18,
                            margin: const EdgeInsets.only(left: 3),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  style: theme.textTheme.bodyLarge?.copyWith(
                      color: user ? scheme.onPrimary : scheme.onSurface,
                      height: 1.35),
                ),
              if (entry.error != null)
                Text(entry.error!, style: TextStyle(color: scheme.error)),
              if (entry.stopped) Text('Stopped', style: muted),
              if (entry.stats != null && entry.stats!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(entry.stats!, style: muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thinking extends StatefulWidget {
  const _Thinking({required this.text});

  final String text;

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> {
  bool open = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => open = !open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.psychology_outlined, size: 16, color: color),
                const SizedBox(width: 4),
                Text('Thinking',
                    style: theme.textTheme.labelMedium?.copyWith(color: color)),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: color),
              ],
            ),
          ),
          if (open)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                    left: BorderSide(
                        color: color.withValues(alpha: 0.4), width: 2)),
              ),
              child: Text(widget.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: color, fontStyle: FontStyle.italic, height: 1.35)),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.streaming,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool streaming;
  final bool enabled;
  final void Function([String?]) onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (value) => onSend(value),
                decoration: InputDecoration(
                  hintText: enabled ? 'Message' : 'Connect to Ollama first',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            streaming
                ? IconButton.filledTonal(
                    key: const Key('stop'),
                    tooltip: 'Stop',
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_rounded),
                  )
                : IconButton.filled(
                    key: const Key('send'),
                    tooltip: 'Send',
                    onPressed: enabled ? () => onSend() : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
          ],
        ),
      ),
    );
  }
}
