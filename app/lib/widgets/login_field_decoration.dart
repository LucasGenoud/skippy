import 'package:flutter/material.dart';

/// The shared dress of the login form's inputs.
///
/// Both [LoginField] implementations — the native one built on [TextField] and
/// the web one built on a real DOM `<input>` — decorate themselves with this,
/// so the two paths stay visually identical.
InputDecoration loginFieldDecoration(
  BuildContext context, {
  required String label,
  required IconData icon,
  String? errorText,
  bool rejected = false,
  Widget? suffixIcon,
}) {
  final scheme = Theme.of(context).colorScheme;
  // A rejected submit flags the field with a red outline and no extra text —
  // the banner above the button already carries the message.
  final rejectedBorder = OutlineInputBorder(
    borderSide: BorderSide(color: scheme.error, width: 2),
  );
  return InputDecoration(
    labelText: label,
    border: const OutlineInputBorder(),
    prefixIcon: Icon(icon),
    errorText: errorText,
    enabledBorder: rejected ? rejectedBorder : null,
    focusedBorder: rejected ? rejectedBorder : null,
    suffixIcon: suffixIcon,
  );
}
