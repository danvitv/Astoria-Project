import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../../core/credentials/cloud_oauth_transport.dart';
import '../../sync_models.dart';

class GDriveFolders {
  // Per-channel, so stable / staging / nightly get sibling folders in the
  // user's Drive root instead of writing into one shared tree.
  static const _folderName = cloudRootFolderName;

  final Dio _dio;

  final Map<String, String> _folderIdCache = {};
  String? _glazeFolderId;
  final Future<CloudOAuthRequestToken> Function() _getRequestToken;
  final void Function() _check;

  GDriveFolders(this._getRequestToken, {Dio? dio, void Function()? check})
    : _check = check ?? _noCheck,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  static void _noCheck() {}

  String? get glazeFolderId => _glazeFolderId;

  void setGlazeFolderId(String? v) => _glazeFolderId = v;

  void invalidateCache() {
    _folderIdCache.clear();
    _glazeFolderId = null;
  }

  Future<String> getGlazeFolderId() async {
    if (_glazeFolderId != null) return _glazeFolderId!;
    final found = await _findFolderByName(_folderName, 'root');
    _check();
    if (found != null) {
      _glazeFolderId = found;
      _folderIdCache['/$_folderName'] = found;
      return found;
    }

    return await createFolder(_folderName, 'root');
  }

  Future<String> ensureFolder(String path) async {
    _check();
    final cached = _folderIdCache[path];
    if (cached != null) return cached;

    final parts = path.split('/').where((s) => s.isNotEmpty).toList();

    var parentId = 'root';
    var currentPath = '';

    for (final part in parts) {
      currentPath += '/$part';
      final cachedId = _folderIdCache[currentPath];
      if (cachedId != null) {
        parentId = cachedId;
        continue;
      }

      var folderId = await _findFolderByName(part, parentId);
      _check();
      folderId ??= await createFolder(part, parentId);
      _check();
      _folderIdCache[currentPath] = folderId;
      parentId = folderId;
    }

    _folderIdCache[path] = parentId;
    return parentId;
  }

  Future<String> resolvePathToParent(String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return await getGlazeFolderId();

    final folderParts = parts.sublist(0, parts.length - 1);
    final folderPath = '/${folderParts.join('/')}';
    return await ensureFolder(folderPath);
  }

  Future<String> createFolder(String name, String parentId) async {
    final token = await _getRequestToken();
    _check();
    final response = await _dio.post<Map<String, dynamic>>(
      'https://www.googleapis.com/drive/v3/files',
      data: jsonEncode({
        'name': name,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parentId],
      }),
      options: Options(
        headers: {
          'Authorization': 'Bearer ${token.value}',
          'Content-Type': 'application/json',
        },
        extra: CloudOAuthRequestScope.tokenAdmission(token),
      ),
    );
    _check();
    final id = response.data?['id'] as String;
    return id;
  }

  Future<void> deleteFolder(String path) async {
    var folderId = _folderIdCache[path];
    if (folderId == null && path == '/$_folderName') {
      folderId = await _findFolderByName(_folderName, 'root');
      _check();
    }
    if (folderId == null) {
      return;
    }
    final token = await _getRequestToken();
    _check();
    await _dio.delete<void>(
      'https://www.googleapis.com/drive/v3/files/$folderId',
      options: Options(
        headers: {'Authorization': 'Bearer ${token.value}'},
        extra: CloudOAuthRequestScope.tokenAdmission(token),
      ),
    );
    _check();
    _folderIdCache.remove(path);
    if (path == '/$_folderName') _glazeFolderId = null;
  }

  Future<String?> _findFolderByName(String name, String parentId) async {
    try {
      final query =
          "name='$name' and '$parentId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false";
      final token = await _getRequestToken();
      _check();
      final response = await _dio.get<Map<String, dynamic>>(
        'https://www.googleapis.com/drive/v3/files',
        queryParameters: {'q': query, 'fields': 'files(id,name)'},
        options: Options(
          headers: {'Authorization': 'Bearer ${token.value}'},
          extra: CloudOAuthRequestScope.tokenAdmission(token),
        ),
      );
      _check();
      final files = response.data?['files'] as List? ?? [];
      if (files.isEmpty) return null;
      return files[0]['id'] as String;
    } catch (_) {
      rethrow;
    }
  }
}
