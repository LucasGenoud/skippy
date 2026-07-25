import 'package:flutter/material.dart';

import 'login_field_decoration.dart';

/// A login input backed by a normal [TextField]. See `login_field.dart`.
class LoginField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final IconData icon;

  /// The autofill hint, e.g. [AutofillHints.username]. Doubles as the
  /// `autocomplete` attribute on the web.
  final String autofillHint;

  /// The `name`/`id` of the DOM input on the web — password managers weigh
  /// those alongside `autocomplete`. Unused on this platform.
  final String fieldName;

  final bool autofocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final TextCapitalization textCapitalization;
  final String? errorText;

  /// Paints the outline in the error colour without an error message.
  final bool rejected;

  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const LoginField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.icon,
    required this.autofillHint,
    required this.fieldName,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.textCapitalization = TextCapitalization.none,
    this.errorText,
    this.rejected = false,
    this.suffixIcon,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      autofillHints: [autofillHint],
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: loginFieldDecoration(
        context,
        label: label,
        icon: icon,
        errorText: errorText,
        rejected: rejected,
        suffixIcon: suffixIcon,
      ),
    );
  }
}
