import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'login_field_decoration.dart';

/// Platform view types have to be unique per element, and the login form
/// rebuilds its fields when the user flips between signing in and creating an
/// account, so hand out a fresh one each time.
int _nextViewId = 0;

/// Flutter's autofill hints are not all valid HTML `autocomplete` tokens,
/// `password` and `newPassword` in particular are `current-password` and
/// `new-password` in the browser, and anything unrecognized is dropped on the
/// floor, which is exactly the field a manager most needs to see.
const _browserAutocomplete = <String, String>{
  AutofillHints.password: 'current-password',
  AutofillHints.newPassword: 'new-password',
};

/// A login input backed by a real DOM `<input>`. See `login_field.dart` for
/// why the web does not use a [TextField] here.
///
/// The Flutter side keeps only the decoration: the [InputDecorator] draws the
/// outline, the floating label and the icons exactly as [TextField] would,
/// while the text itself lives in an `<input>` hosted by a platform view. The
/// [controller] and the element mirror each other in both directions, so the
/// rest of the screen, validation, submit, error clearing, is unchanged, and
/// a password manager writing into the element is indistinguishable from
/// typing.
class LoginField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final IconData icon;

  /// The autofill hint, e.g. [AutofillHints.username]. Used verbatim as the
  /// element's `autocomplete` attribute, the values line up.
  final String autofillHint;

  /// The element's `name`/`id`. Password managers weigh those alongside
  /// `autocomplete`, so they stay human-meaningful (`email`, `password`).
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
  State<LoginField> createState() => _LoginFieldState();
}

class _LoginFieldState extends State<LoginField> {
  late final String _viewType;
  late final web.HTMLInputElement _input;
  late final JSFunction _onInputJs;
  late final JSFunction _onFocusJs;
  late final JSFunction _onBlurJs;
  late final JSFunction _onKeyDownJs;

  bool _focused = false;
  late bool _empty;

  @override
  void initState() {
    super.initState();
    _empty = widget.controller.text.isEmpty;
    _viewType = 'login-field-${_nextViewId++}';
    _input = web.HTMLInputElement()
      ..type = widget.obscureText ? 'password' : 'text'
      ..name = widget.fieldName
      ..id = 'skippy-${widget.fieldName}'
      ..autocomplete =
          _browserAutocomplete[widget.autofillHint] ?? widget.autofillHint
      ..spellcheck = false
      ..value = widget.controller.text;
    _input.setAttribute('aria-label', widget.label);
    _input.setAttribute(
      'autocapitalize',
      widget.textCapitalization == TextCapitalization.words ? 'words' : 'off',
    );
    if (widget.keyboardType == TextInputType.emailAddress) {
      _input.setAttribute('inputmode', 'email');
    }
    // The element fills the decorator's text slot; everything that would draw
    // a second field (border, background, padding) is the decorator's job.
    _input.style
      ..width = '100%'
      ..height = '100%'
      ..border = 'none'
      ..outline = 'none'
      ..padding = '0'
      ..margin = '0'
      ..backgroundColor = 'transparent';
    // Flutter's web surface disables selection by default for its gesture
    // layer. This field is a real DOM input, so opt it back into the browser's
    // native selection and context-menu behavior. Without this, text cannot
    // be selected in either sign-in or create-account mode.
    _input.style
      ..setProperty('user-select', 'text')
      ..setProperty('-webkit-user-select', 'text')
      ..setProperty('-webkit-touch-callout', 'default');
    _input.style.setProperty('box-sizing', 'border-box');

    _onInputJs = ((web.Event _) => _readElement()).toJS;
    _onFocusJs = ((web.Event _) {
      if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
      if (!_focused) setState(() => _focused = true);
    }).toJS;
    _onBlurJs = ((web.Event _) {
      if (_focused) setState(() => _focused = false);
    }).toJS;
    _onKeyDownJs = ((web.Event event) {
      if ((event as web.KeyboardEvent).key != 'Enter') return;
      // The form has no browser-level submit button, so Enter is ours to
      // handle; stop it before the engine turns it into a Flutter key event.
      event.preventDefault();
      _readElement();
      widget.onSubmitted?.call(_input.value);
    }).toJS;
    _input
      ..addEventListener('input', _onInputJs)
      ..addEventListener('focus', _onFocusJs)
      ..addEventListener('blur', _onBlurJs)
      ..addEventListener('keydown', _onKeyDownJs);

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _input,
    );
    widget.controller.addListener(_controllerChanged);
    widget.focusNode.addListener(_focusChanged);
    if (widget.autofocus) _focusWhenAttached(30);
  }

  @override
  void didUpdateWidget(LoginField old) {
    super.didUpdateWidget(old);
    // The reveal button flips this while the field is on screen.
    if (widget.obscureText != old.obscureText) {
      _input.type = widget.obscureText ? 'password' : 'text';
    }
    // Switching between signing in and creating an account turns the same
    // field from a `current-password` into a `new-password`.
    if (widget.autofillHint != old.autofillHint) {
      _input.autocomplete =
          _browserAutocomplete[widget.autofillHint] ?? widget.autofillHint;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    widget.focusNode.removeListener(_focusChanged);
    _input
      ..removeEventListener('input', _onInputJs)
      ..removeEventListener('focus', _onFocusJs)
      ..removeEventListener('blur', _onBlurJs)
      ..removeEventListener('keydown', _onKeyDownJs)
      ..remove();
    super.dispose();
  }

  /// Pull the element's value into the controller. Covers typing as well as a
  /// password manager writing the value in, both raise `input`.
  void _readElement() {
    final value = _input.value;
    if (widget.controller.text != value) widget.controller.text = value;
    widget.onChanged?.call(value);
  }

  /// Push a value set in Dart (a cleared field, a restored draft) back out.
  void _controllerChanged() {
    if (_input.value != widget.controller.text) {
      _input.value = widget.controller.text;
    }
    final empty = widget.controller.text.isEmpty;
    // Only emptiness reaches the decoration, it decides whether the label
    // floats, so leave the other keystrokes alone.
    if (empty != _empty) setState(() => _empty = empty);
  }

  /// Mirror a focus request made on the Flutter side (`Enter` moving to the
  /// next field, a validation error jumping back) onto the element.
  void _focusChanged() {
    if (widget.focusNode.hasFocus && web.document.activeElement != _input) {
      _input.focus();
    }
  }

  /// The element only exists once the platform view has been composited, so an
  /// autofocus has to wait for it to land in the document.
  ///
  /// Waiting on frames would be the natural thing, but the app goes idle once
  /// the login screen has settled and stops producing them, this has to be a
  /// timer, or the autofocus is simply lost.
  void _focusWhenAttached(int attemptsLeft) {
    if (!mounted) return;
    if (_input.isConnected) {
      _input.focus();
    } else if (attemptsLeft > 0) {
      Timer(
        const Duration(milliseconds: 32),
        () => _focusWhenAttached(attemptsLeft - 1),
      );
    }
  }

  String _css(Color color) =>
      'rgba(${(color.r * 255).round()},${(color.g * 255).round()},'
      '${(color.b * 255).round()},${color.a})';

  /// A CSS `font-family` list from a Flutter [TextStyle].
  ///
  /// Every name is quoted: the theme's family on Apple platforms is
  /// `.SF UI Text`, and a leading dot makes an unquoted CSS identifier
  /// invalid, the whole declaration is then dropped and the input falls back
  /// to the user agent's Arial, which matches nothing else on the screen.
  String _cssFontFamily(TextStyle style) => [
    if (style.fontFamily case final family?) '"$family"',
    ...?style.fontFamilyFallback?.map((family) => '"$family"'),
    'system-ui',
    'sans-serif',
  ].join(', ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge!;
    // The element is plain DOM, so the text style has to be restated in CSS.
    // Font family included: CanvasKit paints its own text and tells the DOM
    // nothing about it.
    _input.style
      ..color = _css(theme.colorScheme.onSurface)
      ..fontSize = '${style.fontSize ?? 16}px'
      ..fontFamily = _cssFontFamily(style);
    _input.style.setProperty('caret-color', _css(theme.colorScheme.primary));

    return Focus(
      focusNode: widget.focusNode,
      child: GestureDetector(
        // Clicks land on the element itself, but the decoration around it,
        // padding, label, icons, is Flutter's, and tapping there should still
        // put the caret in the field the way a TextField does.
        behavior: HitTestBehavior.opaque,
        onTap: () => _input.focus(),
        child: InputDecorator(
          decoration: loginFieldDecoration(
            context,
            label: widget.label,
            icon: widget.icon,
            errorText: widget.errorText,
            rejected: widget.rejected,
            suffixIcon: widget.suffixIcon,
          ).applyDefaults(theme.inputDecorationTheme),
          isFocused: _focused,
          isEmpty: _empty,
          child: SizedBox(
            height: (style.fontSize ?? 16) * 1.5,
            child: HtmlElementView(viewType: _viewType),
          ),
        ),
      ),
    );
  }
}
