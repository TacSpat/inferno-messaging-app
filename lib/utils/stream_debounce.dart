import 'dart:async';
import 'package:flutter/foundation.dart';

extension StreamDebounce<T> on Stream<T> {
  /// Throttle with trailing edge + dedup: emits the first value immediately,
  /// collapses rapid-fire updates into one per [duration] window, and skips
  /// emissions entirely when the new value is identical to what was last
  /// emitted (deep equality via [listEquals] for lists, `==` otherwise).
  Stream<T> debounce(Duration duration) {
    Timer? timer;
    T? pending;
    bool hasPending = false;
    DateTime? lastEmit;
    T? lastEmitted;
    bool hasEmitted = false;
    late StreamController<T> controller;
    StreamSubscription<T>? sub;

    bool same(T a, T b) {
      if (a is List && b is List) return listEquals(a, b);
      return a == b;
    }

    void emit(T data) {
      if (hasEmitted && same(data, lastEmitted as T)) return; // dedup
      lastEmitted = data;
      hasEmitted = true;
      lastEmit = DateTime.now();
      if (!controller.isClosed) controller.add(data);
    }

    controller = StreamController<T>(
      onListen: () {
        sub = listen(
          (data) {
            final now = DateTime.now();
            if (lastEmit == null || now.difference(lastEmit!) > duration) {
              emit(data);
              hasPending = false;
            } else {
              pending = data;
              hasPending = true;
              timer?.cancel();
              timer = Timer(duration, () {
                if (hasPending) {
                  emit(pending as T);
                  hasPending = false;
                }
              });
            }
          },
          onError: (e, st) => controller.addError(e, st),
          onDone: () {
            timer?.cancel();
            if (hasPending) emit(pending as T);
            controller.close();
          },
        );
      },
      onCancel: () {
        timer?.cancel();
        sub?.cancel();
      },
    );

    return controller.stream;
  }
}
