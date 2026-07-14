import 'package:flutter/material.dart';

/// Non-web builds don't play audio inline (the app ships as a web build).
class AudioPlayerBar extends StatelessWidget {
  final String url;
  const AudioPlayerBar({super.key, required this.url});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
