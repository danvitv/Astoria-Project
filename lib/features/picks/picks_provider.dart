import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'picks_models.dart';

/// Public card files live alongside Astoria releases, not in the private app repo.
const kPicksBaseUrl =
    'https://raw.githubusercontent.com/danvitv/Astoria-Project-Release/main/picks';

final _dio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ),
);

final picksIndexProvider = FutureProvider<PicksIndex>((ref) async {
  final res = await _dio.get<String>('$kPicksBaseUrl/index.json');
  final json = jsonDecode(res.data!) as Map<String, dynamic>;
  return PicksIndex.fromJson(json);
});

Future<List<int>> fetchPicksCharacterPng(String relativePath) async {
  final res = await _dio.get<List<int>>(
    '$kPicksBaseUrl/$relativePath',
    options: Options(responseType: ResponseType.bytes),
  );
  return res.data ?? [];
}
