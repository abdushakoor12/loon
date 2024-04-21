import 'package:flutter_test/flutter_test.dart';
import 'package:loon/loon.dart';

void main() {
  group('inc', () {
    test('Correctly increments the ref count', () {
      final store = DepStore();

      store.inc('posts__1');

      expect(store.inspect(), {
        "posts": {
          "1": 1,
        }
      });

      store.inc('posts__1');
      store.inc('posts__1__comments__2');
      store.inc('posts__2');

      expect(store.inspect(), {
        "posts": {
          "1": {
            "__ref": 2,
            "comments": {
              "2": 1,
            },
          },
          "2": 1,
        },
      });
    });
  });

  group("dec", () {
    test('Correctly decrements the ref count', () {
      final store = DepStore();

      store.inc('posts__1');
      store.inc('posts__1');
      store.inc('posts__2');
      store.inc('posts__3');

      expect(store.inspect(), {
        "posts": {
          "1": 2,
          "2": 1,
          "3": 1,
        },
      });

      store.dec('posts__1');

      expect(store.inspect(), {
        "posts": {
          "1": 1,
          "2": 1,
          "3": 1,
        },
      });

      store.dec('posts__1');
      store.dec('posts__2');
      store.dec('posts__3');

      expect(store.inspect(), {});
    });

    test("Retains transient paths to deeper nodes", () {
      final store = DepStore();

      store.inc('posts__1');
      store.inc('posts__2');
      store.inc('posts__1__comments__2');

      expect(store.inspect(), {
        "posts": {
          "1": {
            "__ref": 1,
            "comments": {
              "2": 1,
            },
          },
          "2": 1,
        },
      });

      store.dec('posts__1');

      expect(store.inspect(), {
        "posts": {
          "1": {
            "comments": {
              "2": 1,
            },
          },
          "2": 1,
        },
      });
    });
  });
}
