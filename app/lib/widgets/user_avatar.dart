import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/avatar_cache.dart';
import '../util/motion.dart';

/// A person's round picture, or [fallback] (usually their initial) on the
/// circle when they have none or it has not arrived. The picture fades in
/// over the fallback rather than replacing it in one frame.
class UserAvatar extends StatelessWidget {
  final String? userId;

  /// The picture's version, from the user payload; null when there is none.
  final int? version;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Widget fallback;

  const UserAvatar({
    super.key,
    required this.userId,
    required this.version,
    required this.fallback,
    this.radius = 20,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final circle = CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      child: fallback,
    );
    final id = userId;
    final v = version;
    if (id == null || v == null) {
      return circle;
    }

    final cache = context.read<AvatarCache>();
    return FutureBuilder<ImageProvider?>(
      future: cache.image(id, v),
      initialData: cache.resolved(id, v),
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image == null) {
          return circle;
        }
        return SizedBox.square(
          dimension: radius * 2,
          child: Stack(
            fit: StackFit.expand,
            children: [
              circle,
              ClipOval(
                child: Image(
                  image: image,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: Motion.fadeInFrame,
                  errorBuilder: (context, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
