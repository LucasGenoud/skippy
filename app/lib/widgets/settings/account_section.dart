import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_client.dart';
import '../../state/auth_store.dart';
import '../../theme.dart';
import '../form_dialog.dart';

enum _AccountField { name, email, password }

class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthStore?>()?.user;
    if (user == null) return const SizedBox.shrink();
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('Name'),
          subtitle: Text(user.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context, _AccountField.name),
        ),
        ListTile(
          leading: const Icon(Icons.email_outlined),
          title: const Text('Email'),
          subtitle: Text(user.email),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context, _AccountField.email),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Password'),
          subtitle: const Text('Change your sign-in password'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context, _AccountField.password),
        ),
      ],
    );
  }

  void _open(BuildContext context, _AccountField field) {
    showFormDialog<void>(
      context,
      builder: (_) => _EditAccountDialog(field: field),
    );
  }
}

class DeleteAccountTile extends StatelessWidget {
  const DeleteAccountTile({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
      title: Text('Delete account', style: TextStyle(color: scheme.error)),
      subtitle: const Text('Permanently delete your notes and account'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showFormDialog<void>(
        context,
        builder: (_) => const _DeleteAccountDialog(),
      ),
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your current password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final navigator = Navigator.of(context);
      await context.read<AuthStore>().deleteAccount(
        _password.text,
        beforeSignOut: () => navigator.popUntil((route) => route.isFirst),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.statusCode == 403
            ? 'Current password is incorrect'
            : e.serverMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't delete your account";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FormDialog(
      title: const Text('Delete account?'),
      width: kDialogWidth,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your account, every workspace you own, '
            'and every note inside those workspaces, including notes created '
            'by other people. Your other notes, attachments, settings, and '
            'sessions are also deleted. This cannot be undone.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _delete(),
            decoration: InputDecoration(
              labelText: 'Current password',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _busy ? null : _delete,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Delete account'),
        ),
      ],
    );
  }
}

class _EditAccountDialog extends StatefulWidget {
  final _AccountField field;
  const _EditAccountDialog({required this.field});

  @override
  State<_EditAccountDialog> createState() => _EditAccountDialogState();
}

class _EditAccountDialogState extends State<_EditAccountDialog> {
  late final TextEditingController _value;
  final _currentPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthStore>().user!;
    _value = TextEditingController(
      text: switch (widget.field) {
        _AccountField.name => user.name,
        _AccountField.email => user.email,
        _AccountField.password => '',
      },
    );
  }

  @override
  void dispose() {
    _value.dispose();
    _currentPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  String get _title => switch (widget.field) {
    _AccountField.name => 'Change name',
    _AccountField.email => 'Change email',
    _AccountField.password => 'Change password',
  };

  Future<void> _save() async {
    final value = _value.text.trim();
    String? validation;
    switch (widget.field) {
      case _AccountField.name:
        if (value.length < 2) validation = 'Enter your full name';
        break;
      case _AccountField.email:
        if (!value.contains('@')) validation = 'Enter a valid email address';
        if (_currentPassword.text.isEmpty) {
          validation ??= 'Enter your current password';
        }
        break;
      case _AccountField.password:
        if (_currentPassword.text.isEmpty) {
          validation = 'Enter your current password';
        } else if (value.length < 6) {
          validation = 'Password must be at least 6 characters';
        } else if (value != _confirmPassword.text) {
          validation = "Passwords don't match";
        }
        break;
    }
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = context.read<AuthStore>();
      await switch (widget.field) {
        _AccountField.name => auth.updateAccount(name: value),
        _AccountField.email => auth.updateAccount(
          email: value,
          currentPassword: _currentPassword.text,
        ),
        _AccountField.password => auth.updateAccount(
          currentPassword: _currentPassword.text,
          newPassword: value,
        ),
      };
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.statusCode == 403
            ? 'Current password is incorrect'
            : e.serverMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't update your account";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final changingPassword = widget.field == _AccountField.password;
    final needsCurrentPassword = widget.field != _AccountField.name;
    return FormDialog(
      title: Text(_title),
      width: kDialogWidth,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (needsCurrentPassword) ...[
            TextField(
              controller: _currentPassword,
              autofocus: true,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Current password',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _value,
            autofocus: !needsCurrentPassword,
            obscureText: changingPassword && _obscure,
            keyboardType: widget.field == _AccountField.email
                ? TextInputType.emailAddress
                : null,
            textCapitalization: widget.field == _AccountField.name
                ? TextCapitalization.words
                : TextCapitalization.none,
            autofillHints: switch (widget.field) {
              _AccountField.name => const [AutofillHints.name],
              _AccountField.email => const [AutofillHints.email],
              _AccountField.password => const [AutofillHints.newPassword],
            },
            textInputAction: changingPassword
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: (_) {
              if (!changingPassword) _save();
            },
            decoration: InputDecoration(
              labelText: switch (widget.field) {
                _AccountField.name => 'Full name',
                _AccountField.email => 'New email',
                _AccountField.password => 'New password',
              },
              border: const OutlineInputBorder(),
              prefixIcon: Icon(switch (widget.field) {
                _AccountField.name => Icons.badge_outlined,
                _AccountField.email => Icons.email_outlined,
                _AccountField.password => Icons.password_outlined,
              }),
            ),
          ),
          if (changingPassword) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPassword,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Confirm new password',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.password_outlined),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show passwords' : 'Hide passwords',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
