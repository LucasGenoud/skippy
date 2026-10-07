import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/state/sparse_position.dart';

void main() {
  test('a drop between two neighbours lands halfway', () {
    expect(positionAt([1024, 2048], 1, current: 5000), 1536);
  });

  test('a drop at either end steps one gap past the neighbour', () {
    expect(positionAt([1024, 2048], 0, current: 5000), 0);
    expect(positionAt([1024, 2048], 2, current: 5000), 3072);
  });

  test('an item with nothing to order against keeps its position', () {
    expect(positionAt([], 0, current: 5000), 5000);
  });

  test('an index past the end clamps to it', () {
    expect(positionAt([1024], 9, current: 0), 2048);
  });
}
