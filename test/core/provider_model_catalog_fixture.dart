import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/llm/provider_model_catalog.dart';

import 'native_provider_fixture.dart';

/// Only fake vault and fake final HTTP adapter; no app, socket or user config.
final class ModelCatalogHarness {
  ModelCatalogHarness(ApiConfig row)
    : native = NativeProviderFixture(row: row) {
    service = ProviderModelCatalog(
      readSavedConnection: (id) async {
        await beforeRead?.call();
        return id == native.row.id ? native.row : null;
      },
      credentials: native.credentials,
      auth: native.auth,
      mutations: native.mutations,
      redaction: native.redaction,
      adapterFactory: adapter,
    );
  }
  final NativeProviderFixture native;
  late final ProviderModelCatalog service;
  final requests = <RequestOptions>[];
  final adapters = <ModelCatalogAdapter>[];
  Future<void> Function()? beforeRead, beforeResponse;
  void Function()? onFactory;
  bool current = true;
  int status = 200;
  String response = jsonEncode({
    'data': [
      {'id': 'provider-next'},
      {'id': 'provider-first'},
      {'id': 'provider-next'},
    ],
  });
  final token = CancelToken();

  HttpClientAdapter adapter() {
    onFactory?.call();
    final result = ModelCatalogAdapter(this);
    adapters.add(result);
    return result;
  }

  Future<List<String>> fetch() => service.fetchModelIds(
    connectionId: native.row.id,
    isCurrent: () => current,
    cancelToken: token,
  );
  void close() {
    native.mutations.dispose();
    native.redaction.dispose();
  }
}

final class ModelCatalogAdapter implements HttpClientAdapter {
  ModelCatalogAdapter(this.owner);
  final ModelCatalogHarness owner;
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      final bytes = await requestStream.expand((value) => value).toList();
      if (bytes.isNotEmpty) throw StateError('Catalog cannot upload a prompt.');
    }
    owner.requests.add(options);
    await owner.beforeResponse?.call();
    return ResponseBody.fromString(
      owner.response,
      owner.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}
