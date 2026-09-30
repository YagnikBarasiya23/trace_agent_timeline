import 'dart:async';

import 'package:flutter/material.dart';
import 'package:trace_agent_timeline/trace_agent_timeline.dart';

import 'controls.dart';

void main() => runApp(const TraceDemo());

const _bg = Color(0xFF050505);
const _panel = Color(0xFF0E0E10);
const _line = Color(0x1AFFFFFF);
const _muted = Color(0xFFA1A1AA);
const _accent = Color(0xFF4C8DFF);

class TraceDemo extends StatelessWidget {
  const TraceDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trace — agent run timeline for Flutter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _accent, surface: _panel, error: Color(0xFFFF5F7A)),
      ),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final _trace = TraceController();
  bool _running = false;
  Future<void> Function(TraceStep step)? _retry;

  Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  @override
  void initState() {
    super.initState();
    final autoplay = Uri.base.queryParameters['autoplay'] == '1';
    unawaited(_play(_agent, loop: autoplay));
  }

  Future<void> _play(Future<void> Function() run, {bool loop = false}) async {
    if (_running) return;
    setState(() => _running = true);
    do {
      _retry = null;
      _trace.clear();
      await run();
      if (loop) await _wait(2500);
    } while (loop && mounted);
    if (mounted) setState(() => _running = false);
  }

  Future<void> _stream(TraceStep step, String text) async {
    for (final word in text.split(' ')) {
      step.append('$word ');
      await _wait(45);
    }
  }

  Future<void> _schedule() async {
    final step = _trace.tool('posts.schedule', args: {'at': 'Sat 11:00', 'platform': 'instagram'});
    await _wait(700);
    step.done(result: 'scheduled');
    _trace.finish('Post scheduled with photo');
  }

  Future<void> _agent({bool failImage = false}) async {
    final think = _trace.reasoning();
    await _stream(
      think,
      'The owner wants a weekend offer that reaches students. Check what worked last month, then draft a post with a photo and pick the best time.',
    );
    think.done();

    final summary = _trace.tool('analytics.summary', args: {'days': 30});
    await _wait(900);
    summary.done(result: {'reach': 7200, 'engagementRate': 0.098, 'topPlatform': 'instagram'});

    final group = _trace.parallel();
    final caption = group.tool('draft_caption', args: {'tone': 'friendly', 'offer': '20% off for students'});
    final image = group.tool('generate_image', args: {'prompt': 'Brunch table by a window, morning light'});
    final best = group.tool('best_time', args: {'platform': 'instagram'});
    for (var i = 1; i <= 10; i++) {
      await _wait(120);
      image.progress(i / 10);
      if (i == 4) best.done(result: 'Sat 11:00–13:00');
      if (i == 7) caption.done(result: 'Students, treat yourself: 20% off brunch all weekend.');
    }

    if (failImage) {
      image.fail('Image model timed out after 30s');
      _retry = (step) async {
        _retry = null;
        step.retry();
        for (var i = 1; i <= 10; i++) {
          await _wait(100);
          step.progress(i / 10);
        }
        step.done(result: 'brunch-table.jpg');
        await _schedule();
      };
      return;
    }
    image.done(result: 'brunch-table.jpg');
    await _schedule();
  }

  Stream<Map<String, dynamic>> _anthropicStream() async* {
    const thinking =
        'Reach dipped last week. Compare the two weeks and look at what was posted before suggesting anything.';
    final events = <Map<String, dynamic>>[
      {
        'type': 'message_start',
        'message': {'id': 'msg_1'},
      },
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      },
      for (final word in thinking.split(' '))
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': '$word '},
        },
      {'type': 'content_block_stop', 'index': 0},
      {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'analytics_compare',
          'input': <String, dynamic>{},
        },
      },
      {
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"weeks": [38, 39]}'},
      },
      {'type': 'content_block_stop', 'index': 1},
      {
        'type': 'content_block_start',
        'index': 2,
        'content_block': {'type': 'tool_use', 'id': 'toolu_2', 'name': 'list_posts', 'input': <String, dynamic>{}},
      },
      {
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"week": 39}'},
      },
      {'type': 'content_block_stop', 'index': 2},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
      },
      {'type': 'message_stop'},
    ];
    for (final event in events) {
      await _wait(event['type'] == 'content_block_delta' ? 40 : 250);
      yield event;
    }
  }

  Future<Object?> _runTool(String name, Object? args) async {
    await _wait(name == 'list_posts' ? 1400 : 900);
    return name == 'list_posts' ? {'posts': 2, 'note': 'One post fewer than usual'} : {'week38': 9100, 'week39': 6400};
  }

  @override
  void dispose() {
    _trace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget button(String label, Future<void> Function() run, {bool primary = false}) =>
        PillButton(label: label, primary: primary, onPressed: _running ? null : () => _play(run));
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 28, 20, 40 + MediaQuery.paddingOf(context).bottom),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('AGENT RUN TIMELINE', style: text.labelSmall?.copyWith(letterSpacing: 3, color: _muted)),
                  const SizedBox(height: 10),
                  Text('Trace', style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1)),
                  const SizedBox(height: 8),
                  Text(
                    'Reasoning streams in and folds away, tool calls show their input and output, parallel calls run side by side, and failures offer a retry.',
                    style: text.bodyLarge?.copyWith(color: _muted, height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    height: 380,
                    decoration: BoxDecoration(
                      color: _panel,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _line),
                    ),
                    child: Trace(
                      controller: _trace,
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                      onRetry: (step) => _retry?.call(step),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      button('Run the agent', _agent, primary: true),
                      button('Run with a failure', () => _agent(failImage: true)),
                      button(
                        'Replay an Anthropic stream',
                        () => _trace.fromEvents(_anthropicStream(), format: TraceFormat.anthropic, runTool: _runTool),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: Text(
                      'MIT © 2026 Yagnik Barasiya · respects reduced motion',
                      style: text.bodySmall?.copyWith(color: _muted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
