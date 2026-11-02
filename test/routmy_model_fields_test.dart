import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/image_routmy_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/widgets/model_fields.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credentials/fake_credential_storage.dart';

void main() {
  test('Seedream hides the ignored quality selector', () {
    final seedream = buildRoutmyModelFields(
      const ImageGenSettings(routmyModel: 'bytedance/seedream-5.0-pro'),
      isPublicText: (_) => true,
      isFetching: false,
      onFetchModels: () {},
      onUpdate: (_) {},
      showOptions:
          <T>({
            required title,
            required items,
            required labelBuilder,
            required isSelected,
            required onSelected,
          }) {},
    );
    final generic = buildRoutmyModelFields(
      const ImageGenSettings(routmyModel: 'meta/muse-spark-1.1'),
      isPublicText: (_) => true,
      isFetching: false,
      onFetchModels: () {},
      onUpdate: (_) {},
      showOptions:
          <T>({
            required title,
            required items,
            required labelBuilder,
            required isSelected,
            required onSelected,
          }) {},
    );

    expect(seedream, hasLength(3));
    expect(generic, hasLength(4));
  });

  test(
    'original model rows and deferred picker labels/selections consult native public-text custody',
    () {
      const originalKey = 'SYNTHETIC_MODEL_UI:KEY/+%?';
      const laterKey = 'SYNTHETIC_MODEL_UI_LATE:KEY/+%?';
      final redaction = SecretRedactionCoordinator()
        ..registerSecret(originalKey);
      final owner = ImageRoutmyCredentialOwner(
        vault: CredentialVault(
          storage: FakeCredentialStorage(),
          buildChannel: 'dev',
        ),
        redaction: redaction,
        // Public-text validation neither resolves preferences nor opens the vault.
        originalPreferences: Completer<SharedPreferences>().future,
      );
      final previousSink = activeErrorRedactor;
      final current = SecretRedactionCoordinator();
      addTearDown(() {
        activeErrorRedactor = previousSink;
        owner.dispose();
        redaction.dispose();
        current.dispose();
      });
      final lateId = 'gpt-image-${Uri.encodeComponent(laterKey)}';
      List<String>? pickerItems;
      String Function(String)? pickerLabel;
      void Function(String)? pickerSelect;
      ImageGenSettings? update;
      final fields = buildRoutmyModelFields(
        ImageGenSettings(
          routmyModel: 'gpt-image-$originalKey',
          routmyModels: [
            RoutmyModelInfo(id: 'gpt-image-$originalKey'),
            RoutmyModelInfo(
              id: 'gpt-image-encoded-name',
              name: Uri.encodeComponent(originalKey),
            ),
            const RoutmyModelInfo(
              id: 'openai/gpt-image-2',
              name: 'GPT Image 2',
            ),
            RoutmyModelInfo(id: lateId),
          ],
        ),
        isPublicText: owner.capturePublicTextGuard(),
        isFetching: false,
        onFetchModels: () {},
        onUpdate: (value) => update = value,
        showOptions:
            <T>({
              required String title,
              required List<T> items,
              required String Function(T) labelBuilder,
              required bool Function(T) isSelected,
              required void Function(T) onSelected,
            }) {
              pickerItems = items.cast<String>();
              pickerLabel = (value) => labelBuilder(value as T);
              pickerSelect = (value) => onSelected(value as T);
            },
      );
      final row = fields.first as Row;
      final selector =
          (row.children.first as Expanded).child as MenuSelectorItem;
      expect(selector.currentValue, 'Model unavailable');
      selector.onTap();
      expect(pickerItems, ['openai/gpt-image-2', lateId]);
      expect(pickerLabel!('openai/gpt-image-2'), 'GPT Image 2');
      // The picker is already constructed; no recapture from a replacement JSON.
      current.registerSecret(laterKey);
      activeErrorRedactor = current.redactor;
      expect(pickerLabel!(lateId), 'Model unavailable');
      pickerSelect!(lateId);
      expect(update, isNull);
      pickerSelect!('openai/gpt-image-2');
      expect(update?.routmyModel, 'openai/gpt-image-2');
      expect(update?.routmyModels.map((model) => model.id), [
        'openai/gpt-image-2',
      ]);
    },
  );
}
