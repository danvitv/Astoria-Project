import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/credentials/cloud_oauth_record.dart';
import '../../../../core/credentials/cloud_oauth_transport.dart';

import '../../cloud_adapter.dart';
import '../../sync_models.dart';
import 'gdrive_auth.dart';
import 'gdrive_files.dart';
import 'gdrive_folders.dart';

class GDriveAdapter implements CloudAdapter {
  final GDriveAuth _auth;
  final Dio _dio;
  late final GDriveFolders _folders;
  late final GDriveFiles _files;

  GDriveAdapter(this._auth, {Dio Function()? createDio})
    : _dio =
          createDio?.call() ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
            ),
          ) {
    _auth.requests.protect(_dio, CloudOAuthProvider.gdrive);
    final folderDio =
        createDio?.call() ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
    final fileDio =
        createDio?.call() ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 120),
          ),
        );
    _auth.requests.protect(folderDio, CloudOAuthProvider.gdrive);
    _auth.requests.protect(fileDio, CloudOAuthProvider.gdrive);
    _folders = GDriveFolders(
      _auth.getRequestToken,
      dio: folderDio,
      check: _auth.requests.check,
    );
    _folders.setGlazeFolderId(_auth.folderId);
    _files = GDriveFiles(
      _folders,
      _auth.getRequestToken,
      dio: fileDio,
      check: _auth.requests.check,
      registerSecret: _auth.requests.redaction.registerSecret,
    );
  }

  @override
  Future<bool> isConnected() => Future.value(_auth.isConnected);

  @override
  Future<void> ensureFolder(String path) async {
    return _auth.requests.run(() => _ensureFolder(path));
  }

  Future<void> _ensureFolder(String path) async {
    if (!path.startsWith(cloudBase)) {
      path = '$cloudBase/$path';
    }
    await _folders.ensureFolder(path);
    _auth.requests.check();
  }

  @override
  Future<void> upload(String path, String data) async {
    return _auth.requests.run(() => _upload(path, data));
  }

  Future<void> _upload(String path, String data) async {
    await _ensureParent(path);
    _auth.requests.check();
    await _files.upload(path, data);
  }

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {
    return _auth.requests.run(() => _uploadBinary(path, data));
  }

  Future<void> _uploadBinary(String path, Uint8List data) async {
    await _ensureParent(path);
    _auth.requests.check();
    await _files.uploadBinary(path, data);
  }

  @override
  Future<String> download(String path) =>
      _auth.requests.run(() => _files.download(path));

  @override
  Future<Uint8List> downloadBinary(String path) =>
      _auth.requests.run(() => _files.downloadBinary(path));

  @override
  Future<void> deleteFile(String path) =>
      _auth.requests.run(() => _files.deleteFile(path));

  @override
  Future<void> deleteFolder(String path) =>
      _auth.requests.run(() => _folders.deleteFolder(path));

  @override
  Future<List<CloudFileInfo>> listFolder(String path) async {
    return _auth.requests.run(() => _listFolder(path));
  }

  Future<List<CloudFileInfo>> _listFolder(String path) async {
    final folderId = await _folders.ensureFolder(path);
    _auth.requests.check();

    final result = <CloudFileInfo>[];
    String? pageToken;

    do {
      final queryParams = <String, dynamic>{
        'q': "'$folderId' in parents and trashed=false",
        'fields': 'nextPageToken,files(id,name,mimeType)',
        'pageSize': 100,
      };
      if (pageToken != null) queryParams['pageToken'] = pageToken;

      // Folder creation can perform this workflow's own verified refresh. Issue
      // a token receipt for the actual listing, not one captured before it.
      final token = await _auth.getRequestToken();
      _auth.requests.check();
      final response = await _dio.get<Map<String, dynamic>>(
        'https://www.googleapis.com/drive/v3/files',
        queryParameters: queryParams,
        options: Options(
          headers: {'Authorization': 'Bearer ${token.value}'},
          extra: CloudOAuthRequestScope.tokenAdmission(token),
        ),
      );
      _auth.requests.check();

      final files = response.data?['files'] as List? ?? [];
      for (final f in files.whereType<Map<String, dynamic>>()) {
        result.add(
          CloudFileInfo(
            path: '$path/${f['name']}',
            name: f['name'] as String? ?? '',
            isFolder: f['mimeType'] == 'application/vnd.google-apps.folder',
          ),
        );
      }
      pageToken = response.data?['nextPageToken'] as String?;
    } while (pageToken != null);

    return result;
  }

  @override
  Future<Map<String, dynamic>?> getAccountInfo() => _auth.getAccountInfo();

  @override
  Future<void> invalidateFolderCache() {
    _folders.invalidateCache();
    _files.clearFileIdCache();
    return Future.value();
  }

  String? get glazeFolderId => _folders.glazeFolderId;

  Future<String> getGlazeFolderId() => _auth.requests.run(() async {
    final folder = await _folders.getGlazeFolderId();
    _auth.requests.check();
    await _auth.bindFolder(folder);
    _auth.requests.check();
    return folder;
  });

  Future<void> _ensureParent(String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return;
    final folderPath = '/${parts.sublist(0, parts.length - 1).join('/')}';
    await _folders.ensureFolder(folderPath);
  }
}
