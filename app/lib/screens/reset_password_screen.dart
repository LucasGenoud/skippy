import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../theme.dart';
import '../util/motion.dart';
import '../util/network_error.dart';
import '../widgets/app_logo.dart';
import '../widgets/form_error_banner.dart';
import '../widgets/login_field.dart';

/// The page behind an emailed reset link: choose a new password, using the
/// token in the URL as the only credential.
///
/// Like the public share page it runs outside the signed-in app, with no
/// store and no session. Redeeming the link does not sign anyone in; it hands back
/// the address the mail went to, and [onDone] carries that to the sign-in
/// form so the person only has to type the password they just chose.
class ResetPasswordScreen extends StatefulWidget {
  final String token;
  final Api api;

  /// Called with the account's address once the password has been changed, or
  /// with null when the person gives up on a link that will not resolve.
  final ValueChanged<String?> onDone;

  const ResetPasswordScreen({
    super.key,
    required this.token,
    required this.api,
    required this.onDone,
  });

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();

  bool _obscure = true;
  bool _busy = false;
  String? _passwordError;
  String? _confirmError;
  String? _error;

  /// Set once the server has accepted the new password. Holds the account's
  /// address, which becomes the prefill on the sign-in form.
  String? _changedFor;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _passwordError = 'Choose a password');
      _passwordFocus.requestFocus();
      return;
    }
    // The server holds the same floor; checking here saves a round trip and,
    // more to the point, saves the link, which a rejected attempt would
    // otherwise look like it had spent.
    if (password.length < 6) {
      setState(() => _passwordError = 'Use at least 6 characters');
      _passwordFocus.requestFocus();
      return;
    }
    if (password != _confirm.text) {
      setState(() => _confirmError = "Passwords don't match");
      _confirmFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _passwordError = null;
      _confirmError = null;
    });
    try {
      final email = await widget.api.resetPassword(widget.token, password);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _changedFor = email;
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
    final scheme = theme.colorScheme;
    // Same breakpoint as the sign-in form: a card on wide layouts, edge to
    // edge on phones, so arriving from the email looks like arriving anywhere.
    final isWide = MediaQuery.sizeOf(context).width >= 600;
    final changedFor = _changedFor;
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
                    child: AnimatedSize(
                      duration: Motion.base,
                      curve: Motion.standard,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: Motion.base,
                        switchInCurve: Motion.standard,
                        switchOutCurve: Motion.standard,
                        child: changedFor == null
                            ? _form(theme)
                            : _done(theme, changedFor),
                      ),
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

  Widget _form(ThemeData theme) {
    final error = _error;
    return Column(
      key: const ValueKey('form'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose a new password',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 20),
        AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoginField(
                controller: _password,
                focusNode: _passwordFocus,
                label: 'New password',
                icon: Icons.lock_outline,
                autofillHint: AutofillHints.newPassword,
                autofocus: true,
                obscureText: _obscure,
                errorText: _passwordError,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show' : 'Hide',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                onChanged: (_) {
                  if (_passwordError != null || _error != null) {
                    setState(() {
                      _passwordError = null;
                      _error = null;
                    });
                  }
                },
                onSubmitted: (_) => _confirmFocus.requestFocus(),
              ),
              const SizedBox(height: 16),
              LoginField(
                controller: _confirm,
                focusNode: _confirmFocus,
                label: 'Confirm password',
                icon: Icons.lock_outline,
                autofillHint: AutofillHints.newPassword,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                errorText: _confirmError,
                onChanged: (_) {
                  if (_confirmError != null) {
                    setState(() => _confirmError = null);
                  }
                },
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          FormErrorBanner(message: error),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_reset_outlined),
          label: const Text('Set new password'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : () => widget.onDone(null),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }

  Widget _done(ThemeData theme, String email) {
    final scheme = theme.colorScheme;
    return Column(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle_outline, size: 40, color: scheme.primary),
        const SizedBox(height: 16),
        Text(
          'Password updated',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          // Naming the address makes it obvious which account this was, on a
          // page reached without ever signing in.
          'Sign in as $email with your new password. Any devices that were '
          'already signed in will need it too.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => widget.onDone(email),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          icon: const Icon(Icons.login_outlined),
          label: const Text('Sign in'),
        ),
      ],
    );
  }
}
