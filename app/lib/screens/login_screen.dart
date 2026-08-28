import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/form_dialog.dart';
import '../widgets/form_error_banner.dart';
import '../widgets/login_field.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/auth_store.dart';
import '../util/motion.dart';
import '../util/network_error.dart';

class LoginScreen extends StatefulWidget {
  /// Prefills the email field. Set when someone has just come back from the
  /// password reset page, so the only thing left to type is the password they
  /// chose there.
  final String? initialEmail;

  const LoginScreen({super.key, this.initialEmail});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _nameFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _creating = false;
  bool _obscure = true;

  /// Local validation errors for the empty-field checks and the confirm field.
  /// Shown inline so pressing the button always gives feedback rather than
  /// silently doing nothing.
  String? _nameError;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;

  /// Whether this server can email a reset link. It depends on the
  /// deployment's own mail configuration, so it is asked per server and
  /// re-asked whenever the active one changes.
  bool _resetOffered = false;
  String? _capabilitiesFor;

  @override
  void initState() {
    super.initState();
    final email = widget.initialEmail;
    if (email != null) _email.text = email;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `build` watches the AuthStore, so switching servers lands here first.
    final auth = context.read<AuthStore>();
    final url = auth.activeUrl;
    if (url == _capabilitiesFor) return;
    _capabilitiesFor = url;
    _resetOffered = false;
    _loadCapabilities(auth.api, url);
  }

  Future<void> _loadCapabilities(Api api, String url) async {
    try {
      final capabilities = await api.fetchCapabilities();
      if (!mounted || _capabilitiesFor != url) return;
      setState(() => _resetOffered = capabilities.passwordReset);
    } catch (_) {
      // Unreachable, or a server too old to answer: no reset link offered.
      // Signing in will report the connection failure on its own.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _nameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _setMode(bool creating) {
    if (creating == _creating) return;
    setState(() {
      _creating = creating;
      _nameError = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
    });
    context.read<AuthStore>().clearError();
  }

  Future<void> _submit() async {
    final auth = context.read<AuthStore>();
    final name = _name.text.trim();
    final email = _email.text.trim();
    final password = _password.text;

    // Presence check, show an inline error and focus the first empty field
    // instead of returning silently (the old behaviour gave no feedback).
    final nameError = _creating && name.isEmpty ? 'Enter your name' : null;
    final emailError = email.isEmpty ? 'Enter your email' : null;
    final passwordError = password.isEmpty ? 'Enter your password' : null;
    if (nameError != null || emailError != null || passwordError != null) {
      setState(() {
        _nameError = nameError;
        _emailError = emailError;
        _passwordError = passwordError;
      });
      (nameError != null
              ? _nameFocus
              : emailError != null
              ? _emailFocus
              : _passwordFocus)
          .requestFocus();
      return;
    }

    if (_creating && password != _confirm.text) {
      setState(() => _confirmError = "Passwords don't match");
      _confirmFocus.requestFocus();
      return;
    }
    setState(() {
      _nameError = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
    });
    // Let the platform password manager offer to save these credentials.
    TextInput.finishAutofillContext();
    if (_creating) {
      await auth.registerAccount(name, email, password);
    } else {
      await auth.signIn(email, password);
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final auth = context.read<AuthStore>();
    await _ForgotPasswordDialog.show(
      context,
      api: auth.api,
      initialEmail: _email.text.trim(),
    );
  }

  Future<void> _showAddUrlDialog() async {
    final result = await _ServerUrlDialog.show(context);
    if (result != null && result.isNotEmpty && mounted) {
      await context.read<AuthStore>().addUrl(result);
    }
  }

  Future<void> _showEditUrlDialog(String url) async {
    final result = await _ServerUrlDialog.show(context, initial: url);
    if (result != null && result.isNotEmpty && result != url && mounted) {
      await context.read<AuthStore>().editUrl(url, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final creating = _creating;
    // Flag the relevant fields red on a rejected submit: 401 = both credentials
    // are wrong, 409 = the email is taken. A red outline (no extra text,
    // the banner carries the message) so the inputs themselves signal the error.
    final emailRejected = auth.errorStatus == 401 || auth.errorStatus == 409;
    final passwordRejected = auth.errorStatus == 401;
    // On phones, drop the enclosing card and let the form span the full width
    // so the inputs get all the available space.
    final isWide = MediaQuery.sizeOf(context).width >= 600;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isWide ? 24 : 20,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWide ? 400 : double.infinity,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Brand ─────────────────────────────────────────────
                  const AppLogo(size: 72),
                  const SizedBox(height: 20),
                  Text(
                    'Skippy',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // ── Form ──────────────────────────────────────────────
                  // Wrapped in a card on wide layouts; edge-to-edge on phones.
                  Container(
                    padding: isWide
                        ? const EdgeInsets.all(24)
                        : EdgeInsets.zero,
                    decoration: isWide
                        ? BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(kRadius),
                            border: Border.all(color: scheme.outlineVariant),
                          )
                        : null,
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Mode switch, makes Sign in vs Create explicit.
                          SegmentedButton<bool>(
                            // No leading icons: on narrow phone widths the icon
                            // stole enough room that "Create account" wrapped to
                            // two lines. The labels alone read clearly.
                            segments: const [
                              ButtonSegment(
                                value: false,
                                label: Text('Sign in'),
                              ),
                              ButtonSegment(
                                value: true,
                                label: Text(
                                  'Create account',
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.fade,
                                ),
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
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: creating
                                ? Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: LoginField(
                                      controller: _name,
                                      focusNode: _nameFocus,
                                      label: 'Full name',
                                      icon: Icons.badge_outlined,
                                      autofillHint: AutofillHints.name,
                                      autofocus: true,
                                      textCapitalization:
                                          TextCapitalization.words,
                                      errorText: _nameError,
                                      onChanged: (_) {
                                        if (_nameError != null) {
                                          setState(() => _nameError = null);
                                        }
                                        if (auth.errorStatus != null) {
                                          auth.clearError();
                                        }
                                      },
                                      onSubmitted: (_) =>
                                          _emailFocus.requestFocus(),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          LoginField(
                            controller: _email,
                            focusNode: _emailFocus,
                            label: 'Email',
                            icon: Icons.email_outlined,
                            // Desktop password managers pair a
                            // `username` field with `current-password`.
                            // Our username happens to be an email address,
                            // but marking sign-in as email alone makes many
                            // browser managers treat it as a contact field
                            // instead of a saved-login identifier.
                            autofillHint: creating
                                ? AutofillHints.email
                                : AutofillHints.username,
                            autofocus: !creating,
                            keyboardType: TextInputType.emailAddress,
                            errorText: _emailError,
                            rejected: emailRejected,
                            onChanged: (_) {
                              if (_emailError != null) {
                                setState(() => _emailError = null);
                              }
                              if (auth.errorStatus != null) auth.clearError();
                            },
                            onSubmitted: (_) => _passwordFocus.requestFocus(),
                          ),
                          const SizedBox(height: 16),
                          LoginField(
                            controller: _password,
                            focusNode: _passwordFocus,
                            label: 'Password',
                            icon: Icons.lock_outline,
                            autofillHint: creating
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                            obscureText: _obscure,
                            textInputAction: creating
                                ? TextInputAction.next
                                : TextInputAction.done,
                            errorText: _passwordError,
                            rejected: passwordRejected,
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
                            onChanged: (_) {
                              if (_passwordError != null) {
                                setState(() => _passwordError = null);
                              }
                              if (auth.errorStatus != null) auth.clearError();
                            },
                            onSubmitted: (_) => creating
                                ? _confirmFocus.requestFocus()
                                : _submit(),
                          ),
                          // Forgot password, only while signing in and only
                          // where the server can actually send the mail.
                          AnimatedSize(
                            duration: Motion.fast,
                            curve: Motion.standard,
                            alignment: Alignment.topCenter,
                            child: !creating && _resetOffered
                                ? Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: auth.busy
                                          ? null
                                          : _showForgotPasswordDialog,
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: const Text('Forgot password?'),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // Confirm password, only when creating an account.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: creating
                                ? Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: LoginField(
                                      controller: _confirm,
                                      focusNode: _confirmFocus,
                                      label: 'Confirm password',
                                      icon: Icons.lock_outline,
                                      autofillHint: AutofillHints.newPassword,
                                      obscureText: _obscure,
                                      textInputAction: TextInputAction.done,
                                      errorText: _confirmError,
                                      onSubmitted: (_) => _submit(),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          if (auth.error != null) ...[
                            const SizedBox(height: 16),
                            FormErrorBanner(message: auth.error!),
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
                    onEdit: _showEditUrlDialog,
                    onRemove: (url) => auth.removeUrl(url),
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

/// Asks the server to email a reset link.
///
/// It reports the same thing whether or not the address has an account here,
/// because the server does: telling someone which addresses are registered is
/// exactly what the endpoint refuses to do.
class _ForgotPasswordDialog extends StatefulWidget {
  final Api api;
  final String initialEmail;

  const _ForgotPasswordDialog({required this.api, required this.initialEmail});

  static Future<void> show(
    BuildContext context, {
    required Api api,
    required String initialEmail,
  }) => showFormDialog<void>(
    context,
    builder: (_) => _ForgotPasswordDialog(api: api, initialEmail: initialEmail),
  );

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail,
  );
  bool _busy = false;
  String? _error;

  /// The address the request went out for, once it has. Switches the dialog
  /// to its confirmation.
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.requestPasswordReset(email);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sentTo = email;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.serverMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeConnectionFailure(e, widget.api.baseUrl);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sentTo = _sentTo;
    return FormDialog(
      title: Text(sentTo == null ? 'Reset password' : 'Check your email'),
      width: kDialogWidth,
      content: AnimatedSize(
        duration: Motion.fast,
        curve: Motion.standard,
        alignment: Alignment.topCenter,
        child: sentTo == null ? _form(theme) : _sent(theme, sentTo),
      ),
      actions: sentTo == null
          ? [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: _busy ? null : _send,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send link'),
              ),
            ]
          : [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
    );
  }

  Widget _form(ThemeData theme) {
    final error = _error;
    return Column(
      key: const ValueKey('form'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "We'll email you a link to choose a new password.",
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username],
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _send(),
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          FormErrorBanner(message: error),
        ],
      ],
    );
  }

  Widget _sent(ThemeData theme, String email) {
    final scheme = theme.colorScheme;
    return Row(
      key: const ValueKey('sent'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.mark_email_read_outlined, size: 20, color: scheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'If $email has an account here, a link to choose a new password '
            'is on its way. It works once and expires in an hour.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Adds a new backend URL, or edits a saved one when [initial] is given.
/// Returns the entered URL, or null when dismissed.
class _ServerUrlDialog extends StatefulWidget {
  final String? initial;

  const _ServerUrlDialog({this.initial});

  static Future<String?> show(BuildContext context, {String? initial}) =>
      showFormDialog<String>(
        context,
        builder: (_) => _ServerUrlDialog(initial: initial),
      );

  @override
  State<_ServerUrlDialog> createState() => _ServerUrlDialogState();
}

class _ServerUrlDialogState extends State<_ServerUrlDialog> {
  late final TextEditingController _url;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog(
      title: Text(_editing ? 'Edit Server' : 'Add Server'),
      width: kDialogWidth,
      content: TextField(
        controller: _url,
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
          onPressed: () => Navigator.of(context).pop(_url.text.trim()),
          child: Text(_editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

// ── Backend URL selector widget ──────────────────────────────────────────────

class _BackendUrlSelector extends StatelessWidget {
  final String activeUrl;
  final List<String> savedUrls;
  final ValueChanged<String> onSelected;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onRemove;

  const _BackendUrlSelector({
    required this.activeUrl,
    required this.savedUrls,
    required this.onSelected,
    required this.onAdd,
    required this.onEdit,
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
              trailingIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => onEdit(url),
                    tooltip: 'Edit',
                    visualDensity: VisualDensity.compact,
                  ),
                  if (savedUrls.length > 1 && url != activeUrl)
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      onPressed: () => onRemove(url),
                      tooltip: 'Remove',
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              onPressed: () => onSelected(url),
              child: Text(
                _displayUrl(url),
                style: TextStyle(
                  fontWeight: url == activeUrl
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          MenuItemButton(
            leadingIcon: Icon(Icons.add, size: 18, color: scheme.primary),
            onPressed: onAdd,
            child: Text('Add server…', style: TextStyle(color: scheme.primary)),
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
