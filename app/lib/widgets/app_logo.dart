import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The app's brand mark (the stacked sticky-notes logo), rendered from the
/// bundled SVG so it stays crisp at any size.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/logo.svg',
      width: size,
      height: size,
      semanticsLabel: 'Skippy logo',
    );
  }
}
