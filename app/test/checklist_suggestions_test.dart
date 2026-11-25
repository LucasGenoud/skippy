import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/state/checklist_suggestions.dart';

void main() {
  const history = ['Milk', 'Almond milk', 'Eggs', 'Bread', 'Mint'];

  test('exact prefix and substring matches keep their order', () {
    expect(rankSuggestions(history, 'mi'), ['Milk', 'Mint', 'Almond milk']);
  });

  test('a query a letter or two off still finds the item', () {
    // Swapped, missing, and extra letters.
    expect(rankSuggestions(history, 'mlik'), contains('Milk'));
    expect(rankSuggestions(history, 'egs'), ['Eggs']);
    expect(rankSuggestions(history, 'breadd'), ['Bread']);
    // A word inside the item counts too.
    expect(rankSuggestions(history, 'almnd'), ['Almond milk']);
  });

  test('close matches rank after exact ones', () {
    expect(rankSuggestions(['Mint', 'Mind map'], 'mint'), ['Mint', 'Mind map']);
  });

  test('short or distant queries are not guessed at', () {
    expect(rankSuggestions(history, 'ml'), isEmpty);
    expect(rankSuggestions(history, 'xyzw'), isEmpty);
  });

  test('items already on the list are left out', () {
    expect(
      rankSuggestions(history, 'mlik', exclude: {'milk'}),
      isNot(contains('Milk')),
    );
  });
}
