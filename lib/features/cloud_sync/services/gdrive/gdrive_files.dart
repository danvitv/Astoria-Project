import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/credentials/cloud_oauth_transport.dart';
import '../../cloud_adapter.dart';
import 'gdrive_folders.dart';

class GDriveFiles {
  final Dio _dio;

  final Map<String, String> _fileIdCache = {};
  final GDriveFolders _folders;
  final Future<CloudOAuthRequestToken> Function() _getRequestToken;
  final void Function() _check;
  final void Function(String) _registerSecret;

  GDriveFiles(this._folders, this._getRequestToken, {Dio? dio,
    void Function()? check, void Function(String)? registerSecret})
    : _check = check ?? _noCheck, _registerSecret = registerSecret ?? _noSecret,
      _dio = dio ?? Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 120)));

  static void _noCheck() {}
  static void _noSecret(String _) {}

  void cacheFileId(String path, String id) => _fileIdCache[path] = id;
  String? getCachedFileId(String path) => _fileIdCache[path];
  void clearFileIdCache() => _fileIdCache.clear();

  Future<Options> _tokenOptions({Map<String, dynamic> headers = const {},
    String? contentType, ResponseType? responseType}) async {
    final token = await _getRequestToken();
    _check();
    return Options(headers: {...headers, 'Authorization': 'Bearer ${token.value}'},
      contentType: contentType, responseType: responseType,
      extra: CloudOAuthRequestScope.tokenAdmission(token));
  }

  Future<void> upload(String path, String data) async {
    final parentId = await _folders.resolvePathToParent(path);
    _check();
    final fileName = path.split('/').last;
    final cacheKey = path;

    final existingId = _fileIdCache[cacheKey];
    if (existingId != null) {
      try {
        await _dio.patch<void>(
          'https://www.googleapis.com/upload/drive/v3/files/$existingId?uploadType=media',
          data: data,
          options: await _tokenOptions(headers: {'Content-Type': 'application/json'}),
        );
        _check();
        return;
      } on DioException catch (e) {
        _check();
        if (e.response?.statusCode != 404) rethrow;
        _fileIdCache.remove(cacheKey);
      }
    }

    final fileId = await _findFileByName(fileName, parentId);
    _check();
    if (fileId != null) {
      await _dio.patch<void>(
        'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media',
        data: data,
        options: await _tokenOptions(headers: {'Content-Type': 'application/json'}),
      );
      _check();
      _fileIdCache[cacheKey] = fileId;
      return;
    }

    final boundary = 'glaze_boundary_${DateTime.now().millisecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': fileName,
      'parents': [parentId],
    });

    final body =
        '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json\r\n\r\n'
        '$data\r\n'
        '--$boundary--';

    final response = await _dio.post<Map<String, dynamic>>(
      'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
      data: body,
      options: await _tokenOptions(headers: {'Content-Type': 'multipart/related; boundary=$boundary'}),
    );
    _check();
    final newId = response.data?['id'] as String?;
    if (newId != null) _fileIdCache[cacheKey] = newId;
  }

  Future<void> uploadBinary(String path, Uint8List data) async {
    final parentId = await _folders.resolvePathToParent(path);
    _check();
    final fileName = path.split('/').last;

    final existingId =
        _fileIdCache[path] ?? await _findFileByName(fileName, parentId);
    _check();
    if (existingId != null) {
      await _dio.patch<void>(
        'https://www.googleapis.com/upload/drive/v3/files/$existingId?uploadType=media',
        data: Stream.fromIterable([data]),
        options: await _tokenOptions(headers: {'Content-Type': 'application/octet-stream'},
          contentType: 'application/octet-stream'),
      );
      _check();
      _fileIdCache[path] = existingId;
      return;
    }

    final metaResponse = await _dio.post<Map<String, dynamic>>(
      'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable',
      data: jsonEncode({
        'name': fileName,
        'parents': [parentId],
      }),
      options: await _tokenOptions(headers: {'Content-Type': 'application/json'}),
    );
    _check();
    final location = metaResponse.headers['location']?.first;
    if (location == null) throw Exception('No resumable upload URL');
    _registerSecret(location);
    final uri = Uri.tryParse(location);
    if (uri == null || uri.scheme != 'https' || uri.host != 'www.googleapis.com' ||
        uri.port != 443 || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty ||
        !uri.path.startsWith('/upload/drive/v3/files')) {
      throw StateError('Invalid Google Drive upload location');
    }

    final uploadResponse = await _dio.put<Map<String, dynamic>>(
      location,
      data: Stream.fromIterable([data]),
      options: Options(
        headers: {'Content-Length': data.length.toString()},
        contentType: 'application/octet-stream',
      ),
    );
    _check();
    final newId = uploadResponse.data?['id'] as String?;
    if (newId != null) _fileIdCache[path] = newId;
  }

  Future<String> download(String path) async {
    final fileId = await _resolveFileId(path);
    _check();
    final response = await _dio.get<String>(
      'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
      options: await _tokenOptions(responseType: ResponseType.plain),
    );
    _check();
    return response.data ?? '';
  }

  Future<Uint8List> downloadBinary(String path) async {
    final fileId = await _resolveFileId(path);
    _check();
    final response = await _dio.get<List<int>>(
      'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
      options: await _tokenOptions(responseType: ResponseType.bytes),
    );
    _check();
    return Uint8List.fromList(response.data ?? []);
  }

  Future<void> deleteFile(String path) async {
    final fileId = await _resolveFileId(path);
    _check();
    await _dio.delete<void>(
      'https://www.googleapis.com/drive/v3/files/$fileId',
      options: await _tokenOptions(),
    );
    _check();
    _fileIdCache.remove(path);
  }

  Future<String?> _findFileByName(
    String name,
    String parentId,
  ) async {
    try {
      final query = "name='$name' and '$parentId' in parents and trashed=false";
      final response = await _dio.get<Map<String, dynamic>>(
        'https://www.googleapis.com/drive/v3/files',
        queryParameters: {'q': query, 'fields': 'files(id,name)'},
        options: await _tokenOptions(),
      );
      _check();
      final files = response.data?['files'] as List? ?? [];
      if (files.isEmpty) return null;
      return files[0]['id'] as String;
    } catch (_) { rethrow; }
  }

  Future<String> _resolveFileId(String path) async {
    final cached = _fileIdCache[path];
    if (cached != null) return cached;

    final parentId = await _folders.resolvePathToParent(path);
    _check();
    final fileName = path.split('/').last;
    final fileId = await _findFileByName(fileName, parentId);
    _check();
    if (fileId == null) throw CloudFileNotFoundException(path);
    _fileIdCache[path] = fileId;
    return fileId;
  }
}
