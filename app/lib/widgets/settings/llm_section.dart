import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_client.dart';
import '../../models/note.dart';
import '../../state/settings_store.dart';
import '../form_dialog.dart';
import 'managed_note.dart';
import 'probe_row.dart';

/// Summary row for the user's LLM endpoint; taps into the config dialog.
/// There is no server capability involved, availability is purely whether
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
          'Not configured, works with Ollama or any OpenAI-compatible API';
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

class LlmBehaviorTile extends StatelessWidget {
  const LlmBehaviorTile({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return ListTile(
      leading: const Icon(Icons.tune),
      title: const Text('AI behavior'),
      subtitle: Text(
        settings.llmPrompt.isEmpty
            ? 'Default prompt and allowed note changes'
            : 'Custom prompt and allowed note changes',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _LlmBehaviorDialog.show(context),
    );
  }
}

class LlmRewriteTasksTile extends StatelessWidget {
  const LlmRewriteTasksTile({super.key});

  @override
  Widget build(BuildContext context) {
    final tasks = context.watch<SettingsStore>().llmRewriteTasks;
    return ListTile(
      leading: const Icon(Icons.auto_fix_high_outlined),
      title: const Text('AI rewrite tasks'),
      subtitle: Text('${tasks.length} ${tasks.length == 1 ? 'task' : 'tasks'}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _LlmRewriteTasksDialog.show(context),
    );
  }
}

class _LlmRewriteTasksDialog extends StatefulWidget {
  const _LlmRewriteTasksDialog();

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: const _LlmRewriteTasksDialog(),
      ),
    );
  }

  @override
  State<_LlmRewriteTasksDialog> createState() => _LlmRewriteTasksDialogState();
}

class _LlmRewriteTasksDialogState extends State<_LlmRewriteTasksDialog> {
  late List<NoteRewriteTask> _tasks;

  @override
  void initState() {
    super.initState();
    _tasks = [...context.read<SettingsStore>().llmRewriteTasks];
  }

  Future<void> _edit([int? index]) async {
    final task = await _LlmRewriteTaskDialog.show(
      context,
      index == null ? null : _tasks[index],
    );
    if (task == null || !mounted) return;
    setState(() {
      if (index == null) {
        _tasks.add(task);
      } else {
        _tasks[index] = task;
      }
    });
  }

  void _save() {
    context.read<SettingsStore>().setLlmRewriteTasks(_tasks);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: const Text('AI rewrite tasks'),
    width: 520,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'These actions appear in each note menu. Language, note format, and response-safety instructions are added automatically.',
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _tasks.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_tasks[i].name),
            subtitle: Text(
              _tasks[i].prompt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _edit(i),
            trailing: IconButton(
              tooltip: 'Remove ${_tasks[i].name}',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => _tasks.removeAt(i)),
            ),
          ),
        OutlinedButton.icon(
          onPressed: _edit,
          icon: const Icon(Icons.add),
          label: const Text('Add task'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class _LlmRewriteTaskDialog extends StatefulWidget {
  final NoteRewriteTask? task;

  const _LlmRewriteTaskDialog(this.task);

  static Future<NoteRewriteTask?> show(
    BuildContext context,
    NoteRewriteTask? task,
  ) => showFormDialog<NoteRewriteTask>(
    context,
    builder: (_) => _LlmRewriteTaskDialog(task),
  );

  @override
  State<_LlmRewriteTaskDialog> createState() => _LlmRewriteTaskDialogState();
}

class _LlmRewriteTaskDialogState extends State<_LlmRewriteTaskDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.task?.name ?? '');
    _prompt = TextEditingController(text: widget.task?.prompt ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || prompt.isEmpty) return;
    Navigator.pop(
      context,
      NoteRewriteTask(
        id:
            widget.task?.id ??
            'custom-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        prompt: prompt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: Text(widget.task == null ? 'Add rewrite task' : 'Edit rewrite task'),
    width: 520,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Task name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _prompt,
          minLines: 5,
          maxLines: 12,
          maxLength: 4000,
          decoration: const InputDecoration(labelText: 'Prompt'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class _LlmBehaviorDialog extends StatefulWidget {
  const _LlmBehaviorDialog();

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: const _LlmBehaviorDialog(),
      ),
    );
  }

  @override
  State<_LlmBehaviorDialog> createState() => _LlmBehaviorDialogState();
}

class _LlmBehaviorDialogState extends State<_LlmBehaviorDialog> {
  late final TextEditingController _prompt;
  late bool _create;
  late bool _edit;
  late bool _organize;
  late bool _autoSummarizeLinks;
  late UrlSummaryLength _linkSummaryLength;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    _prompt = TextEditingController(text: settings.llmPrompt);
    _create = settings.llmChatCreateEnabled;
    _edit = settings.llmChatEditEnabled;
    _organize = settings.llmChatOrganizeEnabled;
    _autoSummarizeLinks = settings.autoSummarizeLinks;
    _linkSummaryLength = settings.linkSummaryLength;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    context.read<SettingsStore>().setLlmBehavior(
      prompt: _prompt.text,
      create: _create,
      edit: _edit,
      organize: _organize,
    );
    context.read<SettingsStore>().setLinkSummarySettings(
      automatically: _autoSummarizeLinks,
      length: _linkSummaryLength,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: const Text('AI behavior'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _prompt,
          minLines: 3,
          maxLines: 6,
          maxLength: 4000,
          decoration: const InputDecoration(
            labelText: 'Custom instructions',
            hintText: 'Example: Reply in French and keep notes concise.',
            helperText: 'Used by chat, labeling, note editing, and summaries.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatically summarize new links'),
          subtitle: const Text('Only while a text or Markdown note is open'),
          value: _autoSummarizeLinks,
          onChanged: (value) =>
              setState(() => _autoSummarizeLinks = value ?? false),
        ),
        DropdownButtonFormField<UrlSummaryLength>(
          initialValue: _linkSummaryLength,
          decoration: const InputDecoration(labelText: 'Link summary length'),
          items: const [
            DropdownMenuItem(
              value: UrlSummaryLength.short,
              child: Text('Brief'),
            ),
            DropdownMenuItem(
              value: UrlSummaryLength.medium,
              child: Text('Standard'),
            ),
            DropdownMenuItem(
              value: UrlSummaryLength.long,
              child: Text('Detailed'),
            ),
          ],
          onChanged: (value) => setState(() => _linkSummaryLength = value!),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Create notes'),
          value: _create,
          onChanged: (value) => setState(() => _create = value ?? false),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Edit note content'),
          value: _edit,
          onChanged: (value) => setState(() => _edit = value ?? false),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Organize notes'),
          subtitle: const Text('Pin, archive, trash, color, and reminders'),
          value: _organize,
          onChanged: (value) => setState(() => _organize = value ?? false),
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
