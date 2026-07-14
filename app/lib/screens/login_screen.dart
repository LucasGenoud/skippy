import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_store.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _creating = false;
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = context.read<AuthStore>();
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) return;
    if (_creating) {
      await auth.registerAccount(username, password);
    } else {
      await auth.signIn(username, password);
    }
  }

  Future<void> _showAddUrlDialog() async {
    final urlController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Server'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://example.com:8787',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.dns_outlined),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(urlController.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    urlController.dispose();
    if (result != null && result.isNotEmpty && mounted) {
      await context.read<AuthStore>().addUrl(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.sticky_note_2_rounded,
                  size: 64,
                  color: scheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Sticky Notes',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _creating
                      ? 'Create an account to start taking notes'
                      : 'Sign in to your notes',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                // ── Backend URL selector ────────────────────────────
                _BackendUrlSelector(
                  activeUrl: auth.activeUrl,
                  savedUrls: auth.savedUrls,
                  onSelected: (url) => auth.setActiveUrl(url),
                  onAdd: _showAddUrlDialog,
                  onRemove: (url) => auth.removeUrl(url),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _username,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (auth.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    auth.error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: auth.busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: auth.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_creating ? 'Create account' : 'Sign in'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: auth.busy
                      ? null
                      : () => setState(() => _creating = !_creating),
                  child: Text(
                    _creating
                        ? 'Have an account? Sign in'
                        : 'New here? Create an account',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Backend URL selector widget ──────────────────────────────────────────────

class _BackendUrlSelector extends StatelessWidget {
  final String activeUrl;
  final List<String> savedUrls;
  final ValueChanged<String> onSelected;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  const _BackendUrlSelector({
    required this.activeUrl,
    required this.savedUrls,
    required this.onSelected,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: MenuAnchor(
        builder: (context, controller, child) {
          return ActionChip(
            avatar: Icon(
              Icons.dns_outlined,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _displayUrl(activeUrl),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
          );
        },
        menuChildren: [
          ...savedUrls.map(
            (url) => MenuItemButton(
              leadingIcon: url == activeUrl
                  ? Icon(Icons.check, size: 18, color: scheme.primary)
                  : const SizedBox(width: 18),
              trailingIcon: savedUrls.length > 1 && url != activeUrl
                  ? IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      onPressed: () => onRemove(url),
                      tooltip: 'Remove',
                      visualDensity: VisualDensity.compact,
                    )
                  : null,
              onPressed: () => onSelected(url),
              child: Text(
                _displayUrl(url),
                style: TextStyle(
                  fontWeight:
                      url == activeUrl ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          MenuItemButton(
            leadingIcon: Icon(
              Icons.add,
              size: 18,
              color: scheme.primary,
            ),
            onPressed: onAdd,
            child: Text(
              'Add server…',
              style: TextStyle(color: scheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  /// Strip the protocol prefix for a cleaner display.
  String _displayUrl(String url) {
    return url
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/+$'), '');
  }
}
