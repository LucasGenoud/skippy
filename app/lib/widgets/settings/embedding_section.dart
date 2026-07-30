import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/search_stats.dart';
import '../../state/settings_store.dart';
import '../../util/snack.dart';

/// Diagnostics for the semantic-search index, embedding model, vector width,
/// and how many of the user's notes are embedded, plus a button to re-run the
/// embeddings. Shown in Settings under the Semantic search toggle when the
/// server supports semantic search.
class EmbeddingStatsTile extends StatefulWidget {
  const EmbeddingStatsTile({super.key});

  @override
  State<EmbeddingStatsTile> createState() => _EmbeddingStatsTileState();
}

class _EmbeddingStatsTileState extends State<EmbeddingStatsTile> {
  SearchStats? _stats;
  bool _loading = true;
  bool _failed = false;
  bool _reindexing = false;

  /// Live progress of a running re-embed, or null when none is in flight.
  ({int done, int total})? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final stats = await context.read<SettingsStore>().api.fetchSearchStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _failed = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _reindex() async {
    final api = context.read<SettingsStore>().api;
    setState(() {
      _reindexing = true;
      _progress = null;
    });
    try {
      final total = await api.reindexEmbeddings();
      if (total == 0) {
        showAppSnack('No notes to re-embed');
      } else {
        if (mounted) setState(() => _progress = (done: 0, total: total));
        // Poll until the server reports the job finished.
        while (mounted) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          final s = await api.fetchReindexStatus();
          if (!mounted) return;
          setState(() => _progress = (done: s.done, total: s.total));
          if (!s.running) break;
        }
        showAppSnack('Re-embedded $total ${total == 1 ? 'note' : 'notes'}');
      }
    } catch (_) {
      showAppSnack('Could not re-embed');
    } finally {
      if (mounted) {
        setState(() {
          _reindexing = false;
          _progress = null;
        });
      }
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stats = _stats;

    Widget child;
    if (_loading) {
      child = const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Loading index stats…'),
          ],
        ),
      );
    } else if (_failed || stats == null || !stats.enabled) {
      child = Text(
        'Index diagnostics are unavailable.',
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    } else {
      final complete = stats.indexedNotes >= stats.totalNotes;
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatRow(label: 'Model', value: stats.model),
          _StatRow(label: 'Dimensions', value: '${stats.dimensions}'),
          _StatRow(
            label: 'Notes embedded',
            value: '${stats.indexedNotes} / ${stats.totalNotes}',
            hint: complete ? null : 'some notes are not indexed yet',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _reindexing ? null : _reindex,
              icon: _reindexing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_reindexing ? 'Re-embedding…' : 'Re-run embeddings'),
            ),
          ),
          if (_reindexing) _ReindexProgress(progress: _progress),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Embedding index',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;

  const _StatRow({required this.label, required this.value, this.hint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A determinate progress bar for a running re-embed job (indeterminate until
/// the first status poll arrives).
class _ReindexProgress extends StatelessWidget {
  final ({int done, int total})? progress;

  const _ReindexProgress({required this.progress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = progress;
    final value = (p != null && p.total > 0) ? p.done / p.total : null;
    return Padding(
      padding: const EdgeInsets.only(top: 12, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: value, minHeight: 6),
          ),
          if (p != null) ...[
            const SizedBox(height: 6),
            Text(
              '${p.done} / ${p.total} embedded',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
