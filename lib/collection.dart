part of loon;

class Collection<T> extends Query<T> {
  Collection(
    super.collection, {
    required super.fromJson,
    required super.toJson,
    required super.persistorSettings,
  }) : super(filter: null, sort: null);

  Document<T> doc(String id) {
    return Document<T>(
      collection: collection,
      id: id,
      fromJson: fromJson,
      toJson: toJson,
      persistorSettings: persistorSettings,
    );
  }

  void clear() {
    Loon._instance._clearCollection(collection);
  }

  Query<T> where(FilterFn<T> filter) {
    return Query<T>(
      collection,
      filter: filter,
      sort: sort,
      fromJson: fromJson,
      toJson: toJson,
      persistorSettings: persistorSettings,
    );
  }

  Query<T> sortBy(SortFn<T> sort) {
    return Query<T>(
      collection,
      filter: filter,
      sort: sort,
      fromJson: fromJson,
      toJson: toJson,
      persistorSettings: persistorSettings,
    );
  }
}
