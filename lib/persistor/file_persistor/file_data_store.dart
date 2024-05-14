import 'dart:convert';
import 'dart:io';
import 'package:encrypt/encrypt.dart';
import 'package:loon/loon.dart';
import 'package:loon/persistor/file_persistor/extensions/future.dart';
import 'package:path/path.dart' as path;

final fileRegex = RegExp(r'^(?!__resolver__)(\w+)\.json$');

class DualFileDataStore {
  late final FileDataStore _plaintextStore;
  late final EncryptedFileDataStore _encryptedStore;

  final String name;

  DualFileDataStore({
    required this.name,
    required Directory directory,
    required Encrypter encrypter,
    bool isHydrated = false,
  }) {
    _plaintextStore = FileDataStore(
      directory: directory,
      name: name,
      isHydrated: isHydrated,
    );
    _encryptedStore = EncryptedFileDataStore(
      name: name,
      encrypter: encrypter,
      directory: directory,
      isHydrated: isHydrated,
    );
  }

  bool hasValue(String path) {
    return _plaintextStore.hasValue(path) || _encryptedStore.hasValue(path);
  }

  Future<void> writePath(String path, Json value, bool encrypted) async {
    // Unhydrated stores must be hydrated before data can be written to them.
    if (!isHydrated) {
      await hydrate();
    }

    // If the document was previously not encrypted and now is, then it should be removed
    // from the plaintext store and added to the encrypted one and vice-versa.
    if (encrypted) {
      if (_plaintextStore.hasValue(path)) {
        _plaintextStore.deletePath(path, recursive: false);
      }
      _encryptedStore.writePath(path, value);
    } else {
      if (_encryptedStore.hasValue(path)) {
        _encryptedStore.deletePath(path, recursive: false);
      }
      _plaintextStore.writePath(path, value);
    }
  }

  Future<void> deletePath(
    String path, {
    bool recursive = true,
  }) async {
    // Unhydrated stores containing the path must be hydrated before the data can be removed.
    if (!isHydrated) {
      await hydrate();
    }

    _plaintextStore.deletePath(path, recursive: recursive);
    _encryptedStore.deletePath(path, recursive: recursive);
  }

  Future<void> hydrate() async {
    if (isHydrated) {
      return;
    }

    await Future.wait([_plaintextStore.hydrate(), _encryptedStore.hydrate()]);
  }

  Future<void> sync() async {
    await Future.wait([_plaintextStore.sync(), _encryptedStore.sync()]);
  }

  Future<void> delete() async {
    await Future.wait([_plaintextStore.delete(), _encryptedStore.delete()]);
  }

  bool get isHydrated {
    return _plaintextStore.isHydrated && _encryptedStore.isHydrated;
  }

  bool get isEmpty {
    return isHydrated && _plaintextStore.isEmpty && _encryptedStore.isEmpty;
  }

  bool get isDirty {
    return _plaintextStore.isDirty || _encryptedStore.isDirty;
  }

  Future<void> graft(DualFileDataStore other, String path) async {
    await Future.wait([
      _plaintextStore.graft(other._plaintextStore, path),
      _encryptedStore.graft(other._encryptedStore, path),
    ]);
  }

  static DualFileDataStore parse(
    File file, {
    required Encrypter encrypter,
    required Directory directory,
  }) {
    final match = fileRegex.firstMatch(path.basename(file.path));
    final name = match!.group(1)!;

    return DualFileDataStore(
      name: name,
      directory: directory,
      encrypter: encrypter,
    );
  }

  /// Returns a flat map of all the values in the plaintext and encrypted data by path.
  (Map<String, Json> plainText, Map<String, Json> encrypted) extractValues() {
    return (_plaintextStore.extractValues(), _encryptedStore.extractValues());
  }
}

class FileDataStore {
  late final Logger _logger;

  /// The file associated with the data store.
  late final File _file;

  /// The data contained within the file data store.
  IndexedValueStore<Json> _store = IndexedValueStore<Json>();

  /// The name of the file data store.
  final String name;

  /// Whether the plaintext store has pending changes that should be persisted.
  bool isDirty = false;

  /// Whether the file data store has been hydrated yet from its persisted file.
  bool isHydrated;

  FileDataStore({
    required this.name,
    required Directory directory,
    this.isHydrated = false,
  }) {
    _file = File("${directory.path}/$name.json");
    _logger = Logger('FileDataStore $name');
  }

  Future<String?> _readFile() {
    return _file.readAsString().catchType<PathNotFoundException>();
  }

  Future<void> _writeFile(String value) {
    return _logger.measure(
      'Write data store $name',
      () => _file.writeAsString(value),
    );
  }

  bool hasValue(String path) {
    return _store.hasValue(path);
  }

  Future<void> writePath(String path, Json value) async {
    // Unhydrated stores must be hydrated before data can be written to them.
    if (!isHydrated) {
      await hydrate();
    }

    _store.write(path, value);

    isDirty = true;
  }

  Future<void> deletePath(
    String path, {
    bool recursive = true,
  }) async {
    // Unhydrated stores containing the path must be hydrated before the data can be removed.
    if (!isHydrated) {
      await hydrate();
    }

    if (_store.hasValue(path) || recursive && _store.hasPath(path)) {
      _store.delete(path, recursive: recursive);
      isDirty = true;
    }
  }

  Future<void> hydrate() async {
    if (isHydrated) {
      return;
    }

    try {
      await _logger.measure(
        'Hydrate',
        () async {
          final encodedStore = await _readFile();
          if (encodedStore != null) {
            _store = IndexedValueStore.fromJson(jsonDecode(encodedStore));
          }
        },
      );

      isHydrated = true;
    } catch (e) {
      // If hydration fails for an existing file, then this file data store is corrupt
      // and should be removed from the file data store index.
      _logger.log('Corrupt file data store $name');
      rethrow;
    }
  }

  Future<void> sync() async {
    if (isEmpty) {
      await delete();
    } else if (isDirty) {
      await persist();
    }
  }

  Future<void> persist() async {
    if (isEmpty) {
      _logger.log('Empty store persist');
      return;
    }

    if (!isDirty) {
      _logger.log('Clean store persist');
      return;
    }

    await _logger.measure(
      'Persist',
      () => _writeFile(jsonEncode(_store.inspect())),
    );

    isDirty = false;
  }

  Future<void> delete() async {
    if (await _file.exists()) {
      await _file.delete();
    }
  }

  bool get isEmpty {
    return isHydrated && _store.isEmpty;
  }

  /// Grafts the data at the given [path] in the other [FileDataStore] onto
  /// this data store at that path.
  Future<void> graft(FileDataStore other, String path) async {
    final List<Future<void>> futures = [];

    // Both data stores involved in the graft operation must be hydrated in order
    // to move the data from one to the other.
    if (!isHydrated) {
      futures.add(hydrate());
    }
    if (!other.isHydrated) {
      futures.add(other.hydrate());
    }

    await Future.wait(futures);

    _store.graft(other._store, path);

    // After the graft, both affected data stores must be marked as dirty.
    isDirty = true;
    other.isDirty = true;
  }

  /// Returns a flat map of all values in the store by path.
  Map<String, Json> extractValues() {
    return _store.extractValues();
  }
}

class EncryptedFileDataStore extends FileDataStore {
  final Encrypter encrypter;

  EncryptedFileDataStore({
    required String name,
    required super.directory,
    required this.encrypter,
    super.isHydrated = false,
  }) : super(name: "$name.encrypted");

  String _encrypt(String plainText) {
    final iv = IV.fromSecureRandom(16);
    return iv.base64 + encrypter.encrypt(plainText, iv: iv).base64;
  }

  String _decrypt(String encrypted) {
    final iv = IV.fromBase64(encrypted.substring(0, 24));
    return encrypter.decrypt64(
      encrypted.substring(24),
      iv: iv,
    );
  }

  @override
  _readFile() async {
    final encodedStore = await super._readFile();

    if (encodedStore != null) {
      return _decrypt(encodedStore);
    }

    return null;
  }

  @override
  _writeFile(String value) async {
    return super._writeFile(_encrypt(value));
  }
}

class FileDataStoreResolver {
  late final File _file;

  IndexedRefValueStore<String> store = IndexedRefValueStore<String>();

  static const name = '__resolver__';

  final _logger = Logger('FileDataStoreResolver');

  FileDataStoreResolver({
    required Directory directory,
  }) {
    _file = File("${directory.path}/$name.json");
  }

  Future<void> hydrate() async {
    try {
      await _logger.measure(
        'Hydrate',
        () async {
          final fileStr = await _file.readAsString();
          store = IndexedRefValueStore(store: jsonDecode(fileStr));
        },
      );
    } catch (e) {
      if (e is PathNotFoundException) {
        _logger.log('Missing resolver file.');
      } else {
        // If hydration fails for an existing file, then this file data store is corrupt
        // and should be removed from the file data store index.
        _logger.log('Corrupt resolver file.');
        rethrow;
      }
    }
  }

  Future<void> persist() async {
    if (store.isEmpty) {
      _logger.log('Empty persist');
      return;
    }

    await _logger.measure(
      'Persist',
      () => _file.writeAsString(jsonEncode(store.inspect())),
    );
  }

  Future<void> delete() async {
    await _logger.measure(
      'Delete',
      () async {
        await _file.delete().catchType<PathNotFoundException>();
        store.clear();
      },
    );
  }
}
