import 'dart:convert';
import 'dart:io';
import 'package:encrypt/encrypt.dart';
import 'package:loon/loon.dart';
import 'package:path/path.dart' as path;

final fileRegex = RegExp(r'^(?!__resolver__)(\w+)(?:\.(encrypted))?\.json$');

class FileDataStore {
  /// The file associated with the data store.
  final File file;

  /// The name of the file data store.
  final String name;

  /// The data contained within the file data store.
  IndexedValueStore<Json> _store = IndexedValueStore<Json>();

  /// Whether the file data store has pending changes that should be persisted.
  bool isDirty = false;

  /// Whether the file data store has been hydrated yet from its persisted file.
  bool isHydrated;

  static final _logger = Logger('FileDataStore');

  FileDataStore({
    required this.file,
    required this.name,
    this.isHydrated = false,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is FileDataStore) {
      return other.name == name;
    }
    return false;
  }

  @override
  int get hashCode => Object.hashAll([name]);

  Future<String> _readFile() {
    return file.readAsString();
  }

  Future<void> _writeFile(String value) {
    return _logger.measure(
      'Write data store $name',
      () => file.writeAsString(value),
    );
  }

  bool has(String path) {
    return _store.has(path);
  }

  Future<void> write(String path, Json value) async {
    // Unhydrated stores must be hydrated before data can be written to them.
    if (!isHydrated) {
      await hydrate();
    }

    _store.write(path, value);
    isDirty = true;
  }

  Future<void> remove(
    String path, {
    bool recursive = true,
  }) async {
    // Unhydrated stores containing the path must be hydrated before the data can be removed.
    if (!isHydrated) {
      await hydrate();
    }

    if (recursive && _store.hasPath(path)) {
      _store.delete(path);
      isDirty = true;
    } else if (_store.has(path)) {
      _store.delete(path, recursive: false);
      isDirty = true;
    }
  }

  Future<void> delete() async {
    if (!file.existsSync()) {
      _logger.log('Attempted to delete non-existent file');
      return;
    }

    await file.delete();
    isDirty = false;
  }

  Future<void> hydrate() async {
    if (isHydrated) {
      return;
    }

    try {
      await _logger.measure(
        'Parse data store $name',
        () async {
          final fileStr = await _readFile();
          _store = IndexedValueStore.fromJson(jsonDecode(fileStr));
        },
      );
      isHydrated = true;
    } catch (e) {
      if (e is PathNotFoundException) {
        _logger.log('Missing file data store $name');
      } else {
        // If hydration fails for an existing file, then this file data store is corrupt
        // and should be removed from the file data store index.
        _logger.log('Corrupt file data store $name');
        rethrow;
      }
    }
  }

  Future<void> persist() async {
    if (_store.isEmpty) {
      _logger.log('Attempted to write empty data store');
      return;
    }

    final encodedStore = await _logger.measure(
      'Persist data store $name',
      () async => jsonEncode(_store.inspect()),
    );

    await _writeFile(encodedStore);

    isDirty = false;
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

  static FileDataStore parse(
    File file, {
    required Encrypter? encrypter,
  }) {
    final match = fileRegex.firstMatch(path.basename(file.path));
    final name = match!.group(1)!;
    final encrypted = match.group(2) != null;

    if (encrypted) {
      if (encrypter == null) {
        throw 'Missing encrypter';
      }

      return EncryptedFileDataStore(
        file: file,
        name: "$name.encrypted",
        encrypter: encrypter,
      );
    }

    return FileDataStore(file: file, name: name);
  }

  static FileDataStore create(
    String name, {
    required bool encrypted,
    required Directory directory,
    required Encrypter? encrypter,
  }) {
    final file = File("${directory.path}/$name.json");

    if (encrypted) {
      if (encrypter == null) {
        throw 'Missing encrypter';
      }

      return EncryptedFileDataStore(
        file: file,
        name: name,
        encrypter: encrypter,
        isHydrated: true,
      );
    }

    return FileDataStore(
      file: file,
      name: name,
      isHydrated: true,
    );
  }

  /// Returns a flat map of all values in the store by path.
  Map<String, Json> extractValues() {
    return _store.extractValues();
  }
}

class EncryptedFileDataStore extends FileDataStore {
  final Encrypter encrypter;

  EncryptedFileDataStore({
    required super.name,
    required super.file,
    required this.encrypter,
    super.isHydrated = false,
  });

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
  Future<String> _readFile() async {
    return _decrypt(await super._readFile());
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
    await _logger.measure(
      'Persist',
      () async {
        if (store.isEmpty) {
          _logger.log('Empty persist');
          return;
        }
        await _file.writeAsString(jsonEncode(store.inspect()));
      },
    );
  }

  Future<void> delete() async {
    await _logger.measure(
      'Delete',
      () async {
        if (!_file.existsSync()) {
          return;
        }
        await _file.delete();
        store.clear();
      },
    );
  }
}
