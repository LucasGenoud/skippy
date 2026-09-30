import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/app_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = AppFontLoader.instance;

  test('the platform font needs nothing loaded', () {
    expect(loader.resolve(AppFont.system), isNull);
  });

  test('a bundled font resolves once loaded and says so', () async {
    var notified = 0;
    void count() => notified++;
    loader.addListener(count);
    addTearDown(() => loader.removeListener(count));

    expect(loader.resolve(AppFont.lora), isNull);
    await loader.load(AppFont.lora);

    expect(loader.resolve(AppFont.lora), 'Lora');
    expect(notified, 1);
  });

  test('every bundled font has all its files', () async {
    for (final font in AppFont.values) {
      await loader.load(font);
      expect(loader.resolve(font), font.family, reason: font.label);
    }
  });
}
