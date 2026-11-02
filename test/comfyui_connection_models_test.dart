import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_connection_service.dart';

// Original loopback-only regression isolated from the credential suite's
// native plugin binding. No HttpOverrides or production HTTP seams are changed.
void main() {
  test('lists ComfyUI loader entries from /object_info', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/object_info');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'CheckpointLoaderSimple': {
            'input': {
              'required': {
                'ckpt_name': [
                  ['a.safetensors', 'b.safetensors'],
                ],
              },
            },
          },
          'UNETLoader': {
            'input': {
              'required': {
                'unet_name': [
                  ['u.safetensors'],
                ],
              },
            },
          },
        }),
      );
      await request.response.close();
    });
    final service = ImageGenConnectionService();
    addTearDown(service.dispose);
    final models = await service.fetchComfyUiModels(
      ImageGenSettings(
        apiType: ImageGenApiType.comfyui,
        comfyui: ComfyUiImageSettings(
          endpoint: 'http://${server.address.address}:${server.port}',
        ),
      ),
    );
    expect(models, ['a.safetensors', 'b.safetensors', 'u.safetensors']);
  });
}
