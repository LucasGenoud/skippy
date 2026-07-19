import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
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
  final _confirm = TextEditingController();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _creating = false;
  bool _obscure = true;

  /// Local validation error for the confirm-password field (create mode).
  String? _confirmError;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _setMode(bool creating) {
    if (creating == _creating) return;
    setState(() {
      _creating = creating;
      _confirmError = null;
    });
    context.read<AuthStore>().clearError();
  }

  Future<void> _submit() async {
    final auth = context.read<AuthStore>();
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) return;
    if (_creating && password != _confirm.text) {
      setState(() => _confirmError = "Passwords don't match");
      _confirmFocus.requestFocus();
      return;
    }
    setState(() => _confirmError = null);
    // Let the platform password manager offer to save these credentials.
    TextInput.finishAutofillContext();
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final creating = _creating;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Brand ─────────────────────────────────────────────
                Icon(
                  Icons.sticky_note_2_rounded,
                  size: 56,
                  color: scheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  'Sticky Notes',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  creating
                      ? 'Create an account to start taking notes'
                      : 'Welcome back — sign in to your notes',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                // ── Card ──────────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(kRadius),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: AutofillGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Mode switch — makes Sign in vs Create explicit.
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: false,
                              label: Text('Sign in'),
                              icon: Icon(Icons.login_outlined),
                            ),
                            ButtonSegment(
                              value: true,
                              label: Text('Create account'),
                              icon: Icon(Icons.person_add_alt_1_outlined),
                            ),
                          ],
                          selected: {creating},
                          onSelectionChanged: auth.busy
                              ? null
                              : (s) => _setMode(s.first),
                          showSelectedIcon: false,
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _username,
                          autofocus: true,
                          textInputAction: TextInputAction.next,
                          autofillHints: [
                            creating
                                ? AutofillHints.newUsername
                                : AutofillHints.username,
                          ],
                          onSubmitted: (_) => _passwordFocus.requestFocus(),
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _password,
                          focusNode: _passwordFocus,
                          obscureText: _obscure,
                          textInputAction: creating
                              ? TextInputAction.next
                              : TextInputAction.done,
                          autofillHints: [
                            creating
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          onSubmitted: (_) => creating
                              ? _confirmFocus.requestFocus()
                              : _submit(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: _obscure ? 'Show' : 'Hide',
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        // Confirm password — only when creating an account.
                        AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          alignment: Alignment.topCenter,
                          child: creating
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: TextField(
                                    controller: _confirm,
                                    focusNode: _confirmFocus,
                                    obscureText: _obscure,
                                    textInputAction: TextInputAction.done,
                                    autofillHints: const [
                                      AutofillHints.newPassword,
                                    ],
                                    onSubmitted: (_) => _submit(),
                                    decoration: InputDecoration(
                                      labelText: 'Confirm password',
                                      border: const OutlineInputBorder(),
                                      prefixIcon:
                                          const Icon(Icons.lock_outline),
                                      errorText: _confirmError,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (auth.error != null) ...[
                          const SizedBox(height: 16),
                          _ErrorBanner(message: auth.error!),
                        ],
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: auth.busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          icon: auth.busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  creating
                                      ? Icons.person_add_alt_1_outlined
                                      : Icons.login_outlined,
                                ),
                          label: Text(
                            creating ? 'Create account' : 'Sign in',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // ── Backend URL selector ──────────────────────────────
                _BackendUrlSelector(
                  activeUrl: auth.activeUrl,
                  savedUrls: auth.savedUrls,
                  onSelected: (url) => auth.setActiveUrl(url),
                  onAdd: _showAddUrlDialog,
                  onRemove: (url) => auth.removeUrl(url),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A soft error banner shown above the submit button.
class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
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
