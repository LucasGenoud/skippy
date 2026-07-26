import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';
import '../form_dialog.dart';
import 'managed_note.dart';
import 'probe_row.dart';

/// Summary row for the user's LLM endpoint; taps into the config dialog.
/// There is no server capability involved — availability is purely whether
/// the user has configured an endpoint and model.
class LlmConfigTile extends StatelessWidget {
  const LlmConfigTile({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final managed = _llmManaged(settings);
    final String summary;
    if (settings.llmConfigured) {
      final host = Uri.tryParse(settings.llmBaseUrl)?.host;
      summary =
          '${settings.llmModel} @ ${(host == null || host.isEmpty) ? settings.llmBaseUrl : host}';
    } else {
      summary =
          'Not configured — works with Ollama or any OpenAI-compatible API';
    }
    return ListTile(
      leading: const Icon(Icons.smart_toy_outlined),
      title: const Text('AI provider'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [Text(summary), if (managed) const ManagedNote()],
      ),
      trailing: Icon(managed ? Icons.lock_outline : Icons.chevron_right),
      onTap: () => _LlmConfigDialog.show(context),
    );
  }
}

/// Are any of the LLM config fields (endpoint/key/model) server-managed?
bool _llmManaged(SettingsStore s) =>
    s.isManaged('llm_base_url') ||
    s.isManaged('llm_api_key') ||
    s.isManaged('llm_model');

/// Endpoint / API key / model editor with a connection probe. Testing uses
/// the current field values (not the saved settings), so the config can be
/// validated before Save.
class _LlmConfigDialog extends StatefulWidget {
  const _LlmConfigDialog();

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: const _LlmConfigDialog(),
      ),
    );
  }

  @override
  State<_LlmConfigDialog> createState() => _LlmConfigDialogState();
}

class _LlmConfigDialogState extends State<_LlmConfigDialog> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _testing = false;
  ({bool ok, String? error})? _testResult;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    _url = TextEditingController(text: settings.llmBaseUrl);
    _key = TextEditingController(text: settings.llmApiKey);
    _model = TextEditingController(text: settings.llmModel);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final api = context.read<SettingsStore>().api;
    final result = await runSettingsProbe(
      () => api.testLlm(
        baseUrl: _url.text.trim(),
        apiKey: _key.text.trim(),
        model: _model.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  void _save() {
    context.read<SettingsStore>().setLlmConfig(
      baseUrl: _url.text,
      apiKey: _key.text,
      model: _model.text,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsStore>();
    final urlManaged = settings.isManaged('llm_base_url');
    final keyManaged = settings.isManaged('llm_api_key');
    final modelManaged = settings.isManaged('llm_model');
    return FormDialog(
      title: const Text('AI provider'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            enabled: !urlManaged,
            decoration: InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://localhost:11434/v1',
              helperText: urlManaged
                  ? 'Set by the server'
                  : 'OpenAI-compatible endpoint, including /v1 '
                        '(Ollama, OpenAI, LM Studio, …)',
              helperMaxLines: 2,
              suffixIcon: urlManaged
                  ? const Icon(Icons.lock_outline, size: 18)
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            enabled: !keyManaged,
            obscureText: !keyManaged,
            decoration: InputDecoration(
              labelText: 'API key',
              // The server never sends a managed key's value, so show a
              // masked placeholder rather than an empty field.
              hintText: keyManaged ? '•••••• (set by the server)' : null,
              helperText: keyManaged
                  ? 'Set by the server'
                  : 'Leave empty for Ollama',
              suffixIcon: keyManaged
                  ? const Icon(Icons.lock_outline, size: 18)
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            enabled: !modelManaged,
            decoration: InputDecoration(
              labelText: 'Model',
              hintText: 'gpt-5-mini, llama3.1, …',
              helperText: modelManaged ? 'Set by the server' : null,
              suffixIcon: modelManaged
                  ? const Icon(Icons.lock_outline, size: 18)
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          ProbeRow(
            testing: _testing,
            result: _testResult,
            onTest: _test,
            icon: Icons.bolt_outlined,
            label: 'Test connection',
            successText: 'Connected',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
