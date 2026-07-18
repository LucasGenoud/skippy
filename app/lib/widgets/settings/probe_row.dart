import 'package:flutter/material.dart';

import '../../api/api_client.dart';

/// Run a settings probe (LLM test, notification test), folding transport
/// errors into the same `(ok, error)` shape the server reports.
Future<({bool ok, String? error})> runSettingsProbe(
  Future<({bool ok, String? error})> Function() probe,
) async {
  try {
    return await probe();
  } on ApiException catch (e) {
    return (ok: false, error: e.serverMessage);
  } catch (_) {
    return (ok: false, error: 'could not reach the server');
  }
}

/// The "test this configuration" row shared by the settings config dialogs:
/// a probe button (spinner while [testing]) with the latest [result] beside
/// it. A null [onTest] disables the button.
class ProbeRow extends StatelessWidget {
  final bool testing;
  final ({bool ok, String? error})? result;
  final VoidCallback? onTest;
  final IconData icon;
  final String label;

  /// Shown when the probe succeeded (e.g. "Connected").
  final String successText;

  const ProbeRow({
    super.key,
    required this.testing,
    required this.result,
    required this.onTest,
    required this.icon,
    required this.label,
    required this.successText,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = this.result;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: testing ? null : onTest,
          icon: testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 18),
          label: Text(label),
        ),
        const SizedBox(width: 12),
        if (result != null)
          Expanded(
            child: Row(
              children: [
                Icon(
                  result.ok ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: result.ok ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result.ok ? successText : (result.error ?? 'failed'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: result.ok ? scheme.onSurfaceVariant : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
