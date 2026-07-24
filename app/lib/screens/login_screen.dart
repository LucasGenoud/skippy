import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/app_logo.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/auth_store.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

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

    // Presence check — show an inline error and focus the first empty field
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
    // Flag the relevant fields red on a rejected submit: 401 = both credentials
    // are wrong, 409 = the email is taken. A red outline (no extra text —
    // the banner carries the message) so the inputs themselves signal the error.
    final emailRejected = auth.errorStatus == 401 || auth.errorStatus == 409;
    final passwordRejected = auth.errorStatus == 401;
    final rejectedBorder = OutlineInputBorder(
      borderSide: BorderSide(color: scheme.error, width: 2),
    );
    // On phones, drop the enclosing card and let the form span the full width
    // so the inputs get all the available space.
    final isWide = MediaQuery.sizeOf(context).width >= 600;
    // This screen has no AppBar, so nothing sets the status-bar icon colour on
    // its own — without this, iOS drew the notch clock/network glyphs in a shade
    // that vanished against the light background. Derive it from the theme so
    // the icons stay legible in both light and dark.
    final overlayStyle =
        (theme.brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(statusBarColor: Colors.transparent);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
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
                            // Mode switch — makes Sign in vs Create explicit.
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
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
                                      child: TextField(
                                        controller: _name,
                                        focusNode: _nameFocus,
                                        autofocus: true,
                                        textInputAction: TextInputAction.next,
                                        autofillHints: const [
                                          AutofillHints.name,
                                        ],
                                        textCapitalization:
                                            TextCapitalization.words,
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
                                        decoration: InputDecoration(
                                          labelText: 'Full name',
                                          border: const OutlineInputBorder(),
                                          prefixIcon: const Icon(
                                            Icons.badge_outlined,
                                          ),
                                          errorText: _nameError,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            TextField(
                              controller: _email,
                              focusNode: _emailFocus,
                              autofocus: !creating,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              // Desktop password managers pair a
                              // `username` field with `current-password`.
                              // Our username happens to be an email address,
                              // but marking sign-in as email alone makes many
                              // browser managers treat it as a contact field
                              // instead of a saved-login identifier.
                              autofillHints: creating
                                  ? const [AutofillHints.email]
                                  : const [AutofillHints.username],
                              onChanged: (_) {
                                if (_emailError != null) {
                                  setState(() => _emailError = null);
                                }
                                if (auth.errorStatus != null) auth.clearError();
                              },
                              onSubmitted: (_) => _passwordFocus.requestFocus(),
                              decoration: InputDecoration(
                                labelText: 'Email',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.email_outlined),
                                errorText: _emailError,
                                enabledBorder: emailRejected
                                    ? rejectedBorder
                                    : null,
                                focusedBorder: emailRejected
                                    ? rejectedBorder
                                    : null,
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
                              onChanged: (_) {
                                if (_passwordError != null) {
                                  setState(() => _passwordError = null);
                                }
                                if (auth.errorStatus != null) auth.clearError();
                              },
                              onSubmitted: (_) => creating
                                  ? _confirmFocus.requestFocus()
                                  : _submit(),
                              decoration: InputDecoration(
                                labelText: 'Password',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.lock_outline),
                                errorText: _passwordError,
                                enabledBorder: passwordRejected
                                    ? rejectedBorder
                                    : null,
                                focusedBorder: passwordRejected
                                    ? rejectedBorder
                                    : null,
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
                                          prefixIcon: const Icon(
                                            Icons.lock_outline,
                                          ),
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
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
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
