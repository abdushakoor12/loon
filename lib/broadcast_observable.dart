part of loon;

typedef BroadcastObservableChangeRecord<T> = (T prev, T next);

mixin BroadcastObservable<T> {
  late final StreamController<BroadcastObservableChangeRecord<T>> _controller;
  late final Stream<T> broadcastStream;
  late T value;
  late T prevValue;

  T get();

  void observe(T initialValue) {
    _controller =
        StreamController<BroadcastObservableChangeRecord<T>>(onCancel: dispose);
    broadcastStream = _controller.stream.map((record) {
      final (_, next) = record;
      return next;
    });
    prevValue = value = initialValue;

    rebroadcast(get());
    Loon._instance.addBroadcastObserver(this);
  }

  void dispose() {
    _controller.close();
    Loon._instance.removeBroadcastObserver(this);
  }

  void rebroadcast(T updatedValue) {
    prevValue = value;
    value = updatedValue;
    _controller.add((prevValue, value));
  }

  Stream<T> stream() {
    return broadcastStream;
  }

  Stream<BroadcastObservableChangeRecord<T>> streamChanges() {
    return _controller.stream;
  }

  void _onBroadcast();
}
