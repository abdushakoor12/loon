import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loon/loon.dart';
import 'package:loon/persistor/file_persistor/file_persistor.dart';

// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'models/test_user_model.dart';
import 'utils.dart';

late Directory testDirectory;

class MockPathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  getApplicationDocumentsDirectory() {
    return testDirectory;
  }

  @override
  getApplicationDocumentsPath() async {
    return testDirectory.path;
  }
}

void main() {
  final completer = PersistorCompleter();

  setUp(() {
    testDirectory = Directory.systemTemp.createTempSync('test_dir');
    final mockPathProvider = MockPathProvider();
    PathProviderPlatform.instance = mockPathProvider;

    Loon.configure(
      persistor: FilePersistor(
        persistenceThrottle: const Duration(milliseconds: 1),
        onPersist: (_) {
          completer.persistComplete();
        },
        onClear: () {
          completer.clearComplete();
        },
      ),
    );
  });

  tearDown(() async {
    testDirectory.deleteSync(recursive: true);
    Loon.clear();
    await completer.onClearComplete;
  });

  group('persist', () {
    test(
      'Persists new documents',
      () async {
        final userCollection = Loon.collection(
          'users',
          fromJson: TestUserModel.fromJson,
          toJson: (user) => user.toJson(),
        );

        userCollection.doc('1').create(TestUserModel('User 1'));
        userCollection.doc('2').create(TestUserModel('User 2'));

        await completer.onPersistComplete;

        final file = File('${testDirectory.path}/loon/users.json');
        final json = jsonDecode(file.readAsStringSync());

        expect(
          json,
          {
            'users:1': {'name': 'User 1'},
            'users:2': {'name': 'User 2'}
          },
        );
      },
    );

    test(
      'Persists updated documents',
      () async {
        final userCollection = Loon.collection(
          'users',
          fromJson: TestUserModel.fromJson,
          toJson: (user) => user.toJson(),
        );

        userCollection.doc('1').create(TestUserModel('User 1'));
        userCollection.doc('2').create(TestUserModel('User 2'));

        await completer.onPersistComplete;

        userCollection.doc('2').update(TestUserModel('User 2 updated'));

        await completer.onPersistComplete;

        final file = File('${testDirectory.path}/loon/users.json');
        final json = jsonDecode(file.readAsStringSync());

        expect(
          json,
          {
            'users:1': {'name': 'User 1'},
            'users:2': {'name': 'User 2 updated'}
          },
        );
      },
    );

    test(
      'Removes deleted documents',
      () async {
        final userCollection = Loon.collection(
          'users',
          fromJson: TestUserModel.fromJson,
          toJson: (user) => user.toJson(),
        );

        userCollection.doc('1').create(TestUserModel('User 1'));
        userCollection.doc('2').create(TestUserModel('User 2'));

        await completer.onPersistComplete;

        userCollection.doc('2').delete();

        await completer.onPersistComplete;

        final file = File('${testDirectory.path}/loon/users.json');
        final json = jsonDecode(file.readAsStringSync());

        expect(
          json,
          {
            'users:1': {'name': 'User 1'}
          },
        );
      },
    );

    test(
      'Deletes empty files',
      () async {
        final userCollection = Loon.collection(
          'users',
          fromJson: TestUserModel.fromJson,
          toJson: (user) => user.toJson(),
        );

        userCollection.doc('1').create(TestUserModel('User 1'));
        userCollection.doc('2').create(TestUserModel('User 2'));

        final file = File('${testDirectory.path}/loon/users.json');

        await completer.onPersistComplete;

        expect(
          file.existsSync(),
          true,
        );

        // If all documents of a file are deleted, the file itself should be deleted.
        userCollection.doc('1').delete();
        userCollection.doc('2').delete();

        await completer.onPersistComplete;

        expect(
          file.existsSync(),
          false,
        );
      },
    );

    test(
      'Persists documents by their persistence key',
      () async {
        final userCollection = Loon.collection(
          'users',
          fromJson: TestUserModel.fromJson,
          toJson: (user) => user.toJson(),
          persistorSettings: FilePersistorSettings(
            getPersistenceKey: (doc) {
              if (doc.id == '1') {
                return 'users';
              }
              return 'other_users';
            },
          ),
        );

        userCollection.doc('1').create(TestUserModel('User 1'));
        userCollection.doc('2').create(TestUserModel('User 2'));

        await completer.onPersistComplete;

        final usersFile = File('${testDirectory.path}/loon/users.json');
        final otherUsersFile =
            File('${testDirectory.path}/loon/other_users.json');
        final usersJson = jsonDecode(usersFile.readAsStringSync());
        final otherUsersJson = jsonDecode(otherUsersFile.readAsStringSync());

        expect(
          usersJson,
          {
            'users:1': {'name': 'User 1'}
          },
        );

        expect(
          otherUsersJson,
          {
            'users:2': {'name': 'User 2'}
          },
        );
      },
    );

    test(
      'Moves documents that change persistence files',
      () async {
        final userCollection = Loon.collection(
          'users',
          fromJson: TestUserModel.fromJson,
          toJson: (user) => user.toJson(),
          persistorSettings: FilePersistorSettings(
            getPersistenceKey: (doc) {
              if (doc.get()?.data.name.endsWith('updated')) {
                return 'updated_users';
              }
              return 'users';
            },
          ),
        );

        userCollection.doc('1').create(TestUserModel('User 1'));
        userCollection.doc('2').create(TestUserModel('User 2'));

        await completer.onPersistComplete;

        userCollection.doc('2').update(TestUserModel('User 2 updated'));

        await completer.onPersistComplete;

        final usersFile = File('${testDirectory.path}/loon/users.json');
        final updatedUsersFile =
            File('${testDirectory.path}/loon/updated_users.json');
        final usersJson = jsonDecode(usersFile.readAsStringSync());
        final updatedUsersJson =
            jsonDecode(updatedUsersFile.readAsStringSync());

        expect(
          usersJson,
          {
            'users:1': {'name': 'User 1'}
          },
        );

        expect(
          updatedUsersJson,
          {
            'users:2': {'name': 'User 2 updated'}
          },
        );
      },
    );
  });
}
