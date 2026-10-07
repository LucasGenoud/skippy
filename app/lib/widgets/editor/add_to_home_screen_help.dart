import 'package:flutter/material.dart';

import '../form_dialog.dart';

/// How to add a widget where the app cannot do it itself.
///
/// iOS exposes no API for placing a widget, so this walks through the system
/// gesture instead. Naming the note in the last step matters: the widget's own
/// picker is where the note is actually chosen, and it is not obvious that the
/// choice happens there rather than here.
class AddToHomeScreenHelp extends StatelessWidget {
  const AddToHomeScreenHelp({super.key, required this.noteTitle});

  final String noteTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = [
      'Touch and hold an empty area of your Home Screen.',
      'Tap the + button in the corner.',
      'Search for Skippy and pick a widget size.',
    ];
    return AppDialog(
      icon: const Icon(Icons.widgets_outlined),
      title: const Text('Add a Skippy widget'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _Step(number: i + 1, text: steps[i]),
            ),
          _Step(
            number: steps.length + 1,
            text:
                'Touch and hold the new widget, tap Edit Widget, '
                'then choose "$noteTitle".',
          ),
          const SizedBox(height: 12),
          Text(
            'Checklist items can be ticked straight from the widget.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}
