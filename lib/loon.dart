library loon;

import 'dart:async';

import 'package:flutter/foundation.dart';

export 'widgets/query_stream_builder.dart';
export 'widgets/document_stream_builder.dart';
export 'persistor/file_persistor/file_persistor.dart';

part 'store_node.dart';
part 'broadcast_observer.dart';
part 'query.dart';
part 'observable_query.dart';
part 'collection.dart';
part 'document.dart';
part 'observable_document.dart';
part 'types.dart';
part 'document_snapshot.dart';
part 'persistor/persistor.dart';
part 'document_change_snapshot.dart';
part 'broadcast_manager.dart';
part 'utils.dart';

class Loon {
  Persistor? persistor;

  static final Loon _instance = Loon._();

  Loon._();

  /// The store of document snapshots indexed by their document path.
  final _documentStore = StoreNode<DocumentSnapshot>();
  // The store of document dependencies indexed by their path.
  final _dependencyStore = StoreNode<Set<Document>>();

  final _broadcastManager = BroadcastManager();

  bool enableLogging = false;

  bool get _isGlobalPersistenceEnabled {
    return persistor?.settings.persistenceEnabled ?? false;
  }

  DocumentSnapshot<T>? getSnapshot<T>(Document<T> doc) {
    return _documentStore.get(doc.path) as DocumentSnapshot<T>?;
  }

  List<DocumentSnapshot<T>> getSnapshots<T>(Collection<T> collection) {
    return (_documentStore.getAll(collection.path)?.values.toList() ?? [])
        as List<DocumentSnapshot<T>>;
  }

  DocumentSnapshot<T> writeDocument<T>(
    Document<T> doc,
    T data, {
    required EventTypes event,
    bool broadcast = true,
    bool persist = true,
  }) {
    _validateDataSerialization(
      data: data,
      fromJson: doc.fromJson,
      toJson: doc.toJson,
    );

    final snap = DocumentSnapshot(doc: doc, data: data);
    _documentStore.write(doc.path, snap);

    if (broadcast) {
      _broadcastManager.write(doc.path, event);
    }

    rebuildDependencies(doc);

    if (persist && doc.isPersistenceEnabled()) {
      persistor!._persistDoc(doc);
    }

    return snap;
  }

  void deleteDocument<T>(Document<T> doc) {
    if (!doc.exists()) {
      return;
    }

    _documentStore.delete(doc.path);
    _dependencyStore.delete(doc.path);

    // On deleting a document, first delete any existing broadcast events for the document and documents *under* it,
    // as they are all invalidated.
    _broadcastManager.delete(doc.path);
    // Then write an event for the removal of the document, which will schedule a broadcast to any observers
    // of the document and its collection.
    _broadcastManager.write(doc.path, EventTypes.removed);

    if (doc.isPersistenceEnabled()) {
      persistor!._persistDoc(doc);
    }
  }

  void deleteCollection(Collection collection) {
    final path = collection.path;
    _documentStore.delete(path);
    _broadcastManager.delete(path);
    _dependencyStore.delete(path);
    // persistor?.delete(path);
  }

  /// Clears all data from the store.
  Future<void> _clearAll({
    bool broadcast = true,
  }) async {
    // Clear the store.
    _documentStore.clear();
    // Clear any documents scheduled for broadcast, as whatever events happened prior to the clear are now irrelevant.
    _broadcastManager.clear();
    // Clear all dependencies of documents.
    _dependencyStore.clear();

    return persistor?._clearAll();
  }

  /// Rebuilds the set of dependencies of the given document based on its updated snapshot.
  void rebuildDependencies(Document doc) {
    final dependenciesBuilder = doc.dependenciesBuilder;

    if (dependenciesBuilder != null) {
      final path = doc.path;
      final deps = doc.dependenciesBuilder?.call(doc.get()!);

      if (deps != null) {
        _dependencyStore.write(path, deps);
      } else if (_dependencyStore.contains(path)) {
        _dependencyStore.delete(path);
      }
    }
  }

  static void configure({
    Persistor? persistor,
    bool enableLogging = false,
  }) {
    _instance.enableLogging = enableLogging;
    _instance.persistor = persistor;
  }

  static Future<void> hydrate() async {
    if (_instance.persistor == null) {
      printDebug('Hydration skipped - no persistor specified');
      return;
    }
    try {
      final data = await _instance.persistor!._hydrate();

      for (final collectionDataStore in data.entries) {
        final collectionName = collectionDataStore.key;
        final documentDataStore = collectionDataStore.value;

        for (final documentDataEntry in documentDataStore.entries) {
          _instance.writeDocument(
            Loon.collection<Json>(collectionName).doc(documentDataEntry.key),
            documentDataEntry.value,
            event: EventTypes.hydrated,
            persist: false,
          );
        }
      }
    } catch (e) {
      // ignore: avoid_print
      printDebug('Error hydrating');
      rethrow;
    }
  }

  static Collection<T> collection<T>(
    String name, {
    FromJson<T>? fromJson,
    ToJson<T>? toJson,
    PersistorSettings? persistorSettings,
    DependenciesBuilder<T>? dependenciesBuilder,
  }) {
    return Document.root.subcollection<T>(
      name,
      fromJson: fromJson,
      toJson: toJson,
      persistorSettings: persistorSettings,
      dependenciesBuilder: dependenciesBuilder,
    );
  }

  static Future<void> clearAll({
    bool broadcast = true,
  }) {
    return Loon._instance._clearAll(broadcast: broadcast);
  }

  /// Schedules a document to be rebroadcasted, updating all listeners that are subscribed to that document.
  static void rebroadcast(Document doc) {
    _instance._broadcastManager.write(doc.path, EventTypes.touched);
  }

  /// Returns a Map of all of the data and metadata of the store for debugging and inspection purposes.
  static Json inspect() {
    return {
      "store": _instance._documentStore.inspect(),
      "broadcastStore": _instance._broadcastManager.inspect(),
      "dependencyStore": _instance._dependencyStore.inspect(),
    };
  }

  static bool get isLoggingEnabled {
    return _instance.enableLogging;
  }
}
