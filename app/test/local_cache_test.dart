import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skippy/state/local_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cache skips identical writes but retries failures and respects clear',
    () async {
      const channel = MethodChannel('plugins.flutter.io/shared_preferences');
      final storage = <String, Object>{};
      var writes = 0;
      var fail = false;
      SharedPreferences.resetStatic();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method.startsWith('getAll')) {
          return storage;
        }
        final args = call.arguments as Map;
        if (call.method == 'remove') {
          storage.remove(args['key']);
          return true;
        }
        if (call.method == 'setString') {
          writes++;
          if (fail) {
            return false;
          }
          storage[args['key'] as String] = args['value'] as String;
          return true;
        }
        throw StateError('Unexpected method: ${call.method}');
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        SharedPreferences.resetStatic();
      });
      final cache = PrefsLocalCache();
      final doc = <String, dynamic>{'notes': [], 'queue': []};
      await cache.write('account-a', doc);
      await cache.write('account-a', {'notes': [], 'queue': []});
      expect(writes, 1);

      fail = true;
      final edited = <String, dynamic>{
        'notes': [],
        'queue': [
          {'id': 'pending'},
        ],
      };
      await expectLater(cache.write('account-a', edited), throwsStateError);
      fail = false;
      await cache.write('account-a', edited);
      expect(writes, 3);
      SharedPreferences.resetStatic();
      expect(await cache.read('account-a'), edited);

      await cache.clear('account-a');
      await cache.write('account-a', edited);
      expect(writes, 4);
      await cache.write('account-b', edited);
      expect(writes, 5);
      SharedPreferences.resetStatic();
      expect(await cache.read('account-a'), edited);
      expect(await cache.read('account-b'), edited);
    },
  );
}
