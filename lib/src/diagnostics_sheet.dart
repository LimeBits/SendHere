import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'launch_log.dart';
import 'theme.dart';

/// The data behind the diagnostics sheet, assembled by the caller so this file
/// has no dependency on the app's state.
class DiagnosticsReport {
  const DiagnosticsReport({required this.facts, required this.log});

  /// Ordered key/value rows: build, OS, address, port, whether the socket is
  /// actually accepting connections, and so on.
  final List<MapEntry<String, String>> facts;

  final String log;

  /// One self-contained blob, which is what gets pasted into a chat. Keeping
  /// the facts and the log together means a single copy carries everything
  /// needed to explain a failed connection.
  String toPlainText() {
    final buffer = StringBuffer('SendHere 诊断信息\n');
    for (final fact in facts) {
      buffer.writeln('${fact.key}: ${fact.value}');
    }
    buffer
      ..writeln()
      ..writeln('--- launch.log ---');
    final trimmed = log.trimRight();
    buffer.write(trimmed.isEmpty ? '(暂无日志)' : trimmed);
    return buffer.toString();
  }
}

/// Opens the diagnostics sheet.
///
/// [collect] runs when the sheet opens, so the snapshot reflects the state at
/// that moment rather than whenever the list was last rebuilt — the socket
/// probe alone makes this worth doing on demand.
Future<void> showDiagnosticsSheet(
  BuildContext context, {
  required Future<DiagnosticsReport> Function() collect,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Same reasoning as the QR sheet: a drag recogniser on the sheet competes
    // with the buttons at the bottom.
    showDragHandle: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (context) => _DiagnosticsSheet(collect: collect),
  );
}

class _DiagnosticsSheet extends StatefulWidget {
  const _DiagnosticsSheet({required this.collect});

  final Future<DiagnosticsReport> Function() collect;

  @override
  State<_DiagnosticsSheet> createState() => _DiagnosticsSheetState();
}

class _DiagnosticsSheetState extends State<_DiagnosticsSheet> {
  DiagnosticsReport? _report;
  Object? _error;
  bool _copied = false;
  Timer? _resetTimer;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final report = await widget.collect();
      if (!mounted) return;
      setState(() {
        _report = report;
        _error = null;
      });
      // The interesting lines are always the last ones, so open the log at the
      // bottom instead of making the reader scroll past a whole session.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report.toPlainText()));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志？'),
        content: const Text('清空后无法恢复。如果还没把内容复制走，请先复制。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: SendHereColors.unread),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LaunchLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: SizedBox(
          height: media.size.height * 0.72,
          child: Column(children: [
            Row(children: [
              const SizedBox(width: 40),
              const Expanded(
                child: Text('诊断',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: SendHereColors.sub,
                  tooltip: '关闭',
                ),
              ),
            ]),
            const SizedBox(height: 2),
            const Text('复制后发给对方，就能看出问题出在哪一步。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: SendHereColors.sub)),
            const SizedBox(height: 14),
            Expanded(child: _buildBody()),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _report == null ? null : _copy,
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 18,
                  ),
                  label: Text(_copied ? '已复制' : '复制全部'),
                  style: FilledButton.styleFrom(
                    backgroundColor: SendHereColors.ink,
                    foregroundColor: SendHereColors.onInk,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(SendHereRadius.small),
                    ),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _report == null ? null : _clear,
                style: TextButton.styleFrom(
                  foregroundColor: SendHereColors.sub,
                  minimumSize: const Size(56, 46),
                ),
                child: const Text('清空', style: TextStyle(fontSize: 13)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Text('无法读取诊断信息\n$error',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: SendHereColors.sub)),
      );
    }
    final report = _report;
    if (report == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Column(children: [
      _FactCard(facts: report.facts),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: Text('最近日志 · ${_lineCount(report.log)} 行',
            style: const TextStyle(fontSize: 12, color: SendHereColors.sub)),
      ),
      const SizedBox(height: 6),
      Expanded(child: _buildLog(report.log)),
    ]);
  }

  Widget _buildLog(String log) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: SendHereColors.paper,
        borderRadius: BorderRadius.circular(SendHereRadius.small),
        border: Border.all(color: SendHereColors.line),
      ),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          // Selectable so a single suspicious line can be picked out without
          // copying the whole trail.
          child: SelectableText(
            log.trim().isEmpty ? '(暂无日志)' : log.trimRight(),
            style: const TextStyle(
              fontSize: 11,
              height: 1.5,
              // Menlo on iOS, the platform monospace on Android; both resolve
              // before the generic family is needed.
              fontFamily: 'monospace',
              fontFamilyFallback: ['Menlo', 'Roboto Mono'],
              color: SendHereColors.ink,
            ),
          ),
        ),
      ),
    );
  }

  static int _lineCount(String log) =>
      log.trim().isEmpty ? 0 : log.trim().split('\n').length;
}

class _FactCard extends StatelessWidget {
  const _FactCard({required this.facts});

  final List<MapEntry<String, String>> facts;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: SendHereColors.chip,
        borderRadius: BorderRadius.circular(SendHereRadius.small),
      ),
      child: Column(children: [
        for (final fact in facts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 74,
                  child: Text(fact.key,
                      style: const TextStyle(
                          fontSize: 12.5, color: SendHereColors.sub)),
                ),
                Expanded(
                  child: Text(fact.value,
                      style: const TextStyle(
                          fontSize: 12.5, color: SendHereColors.ink)),
                ),
              ],
            ),
          ),
      ]),
    );
  }
}
