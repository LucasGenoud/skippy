import 'package:flutter/material.dart';

import '../theme.dart';

/// A soft error banner shown above a form's submit button. Used by the sign-in
/// form and the password reset form, which are the two places someone meets a
/// failure with no app around it to put the message in.
class FormErrorBanner extends StatelessWidget {
  final String message;
  const FormErrorBanner({super.key, required this.message});

  /// Last line of defence against a message-less banner. Callers upstream
  /// (`ApiException.serverMessage`, `describeConnectionFailure`) already
  /// guarantee text, but a red box with nothing in it tells someone their
  /// sign-in failed and then refuses to say how, so the fallback stays.
  static const _fallback = 'Something went wrong. Try again in a moment.';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = this.message.trim().isEmpty ? _fallback : this.message;
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
