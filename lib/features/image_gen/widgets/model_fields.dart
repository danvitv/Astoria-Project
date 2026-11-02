import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'rows.dart' as rows;

/// Callback for showing a single-select options bottom sheet from a
/// model-field row. Kept here so the row constructors don't have to
/// know about [BuildContext] or modal sheet plumbing.
typedef ShowOptionsCallback =
    void Function<T>({
      required String title,
      required List<T> items,
      required String Function(T) labelBuilder,
      required bool Function(T) isSelected,
      required void Function(T) onSelected,
    });

/// Model-field rows for the Naistera image-gen API.
///
/// The model list comes from the catalog loaded via the refresh button
/// (`GET /api/models`) and falls back to the shipped shortlist until then —
/// mirroring the upstream extension, which also stopped hardcoding the
/// Naistera model names.
List<Widget> buildNaisteraModelFields(
  ImageGenSettings s, {
  bool Function(String)? isPublicText,
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  // Settings written by older builds can still hold a retired model label
  // ('nano banana'), so the selector matches on the normalized id.
  bool public(String value) => isPublicText?.call(value) ?? true;
  final catalog = s.naisteraModels
      .where(
        (m) =>
            public(m.id) &&
            public(m.name) &&
            public(NaisteraConstants.normalizeModel(m.id)),
      )
      .map((m) => m.id)
      .toList();
  final model = catalog.contains(s.naisteraModel)
      ? s.naisteraModel
      : NaisteraConstants.normalizeModel(s.naisteraModel);
  final items = catalog.isEmpty
      ? NaisteraConstants.models.map((e) => e.$1).toList()
      : catalog;
  String publicLabel(String value) {
    if (!public(value) || !public(NaisteraConstants.normalizeModel(value)))
      return 'Model unavailable';
    final label = s.naisteraModelLabel(value);
    return public(label) ? label : 'Model unavailable';
  }

  return [
    // MenuSelectorItem has no trailing slot, so the refresh button sits
    // beside it in a row of its own.
    Row(
      children: [
        Expanded(
          child: MenuSelectorItem(
            label: 'imggen_model'.tr(),
            currentValue: s.naisteraModel.isNotEmpty && public(s.naisteraModel)
                ? publicLabel(model)
                : 'Model unavailable',
            onTap: () => showOptions<String>(
              title: 'imggen_model'.tr(),
              items: items
                  .where(
                    (id) =>
                        public(id) &&
                        public(NaisteraConstants.normalizeModel(id)) &&
                        public(s.naisteraModelLabel(id)),
                  )
                  .toList(),
              labelBuilder: publicLabel,
              isSelected: (v) => model == v,
              onSelected: (v) {
                if (public(v) &&
                    public(NaisteraConstants.normalizeModel(v)) &&
                    public(s.naisteraModelLabel(v)))
                  onUpdate(s.copyWith(naisteraModel: v));
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: rows.ImageGenFetchButton(
            isFetching: isFetching,
            onPressed: onFetchModels,
          ),
        ),
      ],
    ),
    MenuSelectorItem(
      label: 'imggen_aspect_ratio'.tr(),
      currentValue: s.naisteraAspectRatio,
      onTap: () => showOptions<String>(
        title: 'imggen_aspect_ratio'.tr(),
        items: NaisteraConstants.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => s.naisteraAspectRatio == v,
        onSelected: (v) => onUpdate(s.copyWith(naisteraAspectRatio: v)),
      ),
    ),
    MenuSelectorItem(
      label: 'imggen_char_descriptions'.tr(),
      description: 'imggen_char_descriptions_desc'.tr(),
      currentValue: _descriptionsModeLabel(s.naisteraCharacterDescriptionsMode),
      onTap: () => showOptions<CharacterDescriptionsMode>(
        title: 'imggen_char_descriptions'.tr(),
        items: CharacterDescriptionsMode.values,
        labelBuilder: _descriptionsModeLabel,
        isSelected: (v) => s.naisteraCharacterDescriptionsMode == v,
        onSelected: (v) =>
            onUpdate(s.copyWith(naisteraCharacterDescriptionsMode: v)),
      ),
    ),
  ];
}

String _descriptionsModeLabel(CharacterDescriptionsMode mode) => switch (mode) {
  CharacterDescriptionsMode.none => 'imggen_char_descriptions_none'.tr(),
  CharacterDescriptionsMode.asIs => 'imggen_char_descriptions_as_is'.tr(),
  CharacterDescriptionsMode.characterPrompt =>
    'imggen_char_descriptions_prompt'.tr(),
};

/// Model-field rows for the rout.my image-gen API. The model list comes from
/// the catalog loaded via the refresh button (`GET /v1/models`) and falls back
/// to the shipped shortlist until then.
List<Widget> buildRoutmyModelFields(
  ImageGenSettings s, {
  required bool Function(String) isPublicText,
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  const seedreamModel = 'bytedance/seedream-5.0-pro';
  final model = s.routmyModel;
  final aspect = s.routmyAspectRatio;
  final size = s.routmyImageSize;
  final quality = s.routmyQuality;
  final catalog = s.routmyModels
      .where((m) => isPublicText(m.id) && isPublicText(m.name))
      .map((m) => m.id)
      .toList();
  final items = catalog.isEmpty
      ? RoutMyConstants.models.map((e) => e.$1).toList()
      : catalog;
  final availableImageSizes = model == seedreamModel
      ? RoutMyConstants.seedreamImageSizes
      : RoutMyConstants.imageSizes;
  String publicLabel(String value) {
    if (!isPublicText(value)) return 'Model unavailable';
    final label = s.routmyModelLabel(value);
    return isPublicText(label) ? label : value;
  }

  return [
    // MenuSelectorItem has no trailing slot, so the refresh button sits
    // beside it in a row of its own.
    Row(
      children: [
        Expanded(
          child: MenuSelectorItem(
            label: 'Model',
            currentValue: publicLabel(model),
            onTap: () => showOptions<String>(
              title: 'Model',
              items: items,
              labelBuilder: publicLabel,
              isSelected: (v) => model == v,
              onSelected: (v) {
                if (!isPublicText(v)) return;
                final seedreamSize =
                    v == seedreamModel &&
                        !RoutMyConstants.seedreamImageSizes.contains(size)
                    ? '2K'
                    : size;
                onUpdate(
                  s.copyWith(
                    routmyModel: v,
                    routmyImageSize: seedreamSize,
                    routmyModels: s.routmyModels
                        .where(
                          (entry) =>
                              isPublicText(entry.id) &&
                              isPublicText(entry.name),
                        )
                        .toList(),
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: rows.ImageGenFetchButton(
            isFetching: isFetching,
            onPressed: onFetchModels,
          ),
        ),
      ],
    ),
    MenuSelectorItem(
      label: 'Aspect Ratio',
      currentValue: aspect,
      onTap: () => showOptions<String>(
        title: 'Aspect Ratio',
        items: RoutMyConstants.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => aspect == v,
        onSelected: (v) => onUpdate(s.copyWith(routmyAspectRatio: v)),
      ),
    ),
    MenuSelectorItem(
      label: 'Resolution',
      currentValue: size,
      onTap: () => showOptions<String>(
        title: 'Resolution',
        items: availableImageSizes,
        labelBuilder: (v) => v,
        isSelected: (v) => size == v,
        onSelected: (v) => onUpdate(s.copyWith(routmyImageSize: v)),
      ),
    ),
    if (model != seedreamModel)
      MenuSelectorItem(
        label: 'Quality',
        currentValue: quality == 'hd' ? 'HD' : 'Standard',
        onTap: () => showOptions<String>(
          title: 'Quality',
          items: ['standard', 'hd'],
          labelBuilder: (v) => v == 'hd' ? 'HD' : 'Standard',
          isSelected: (v) => quality == v,
          onSelected: (v) => onUpdate(s.copyWith(routmyQuality: v)),
        ),
      ),
  ];
}

/// Model-field rows for the OpenAI image-gen API. The "fetch models"
/// suffix is rendered inline — the spinner is bound to [isFetching]
/// and the refresh icon calls [onFetchModels].
List<Widget> buildOpenaiModelFields(
  ImageGenSettings s, {
  required bool isFetching,
  required VoidCallback onFetchModels,
  required ValueChanged<ImageGenSettings> onUpdate,
  required ShowOptionsCallback showOptions,
}) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'Model',
      value: s.customModel,
      hint: 'dall-e-3',
      onChanged: (v) => onUpdate(s.copyWith(customModel: v)),
      suffix: rows.ImageGenFetchButton(
        isFetching: isFetching,
        onPressed: onFetchModels,
      ),
    ),
    MenuSelectorItem(
      label: 'Image Size',
      currentValue: s.openaiSize,
      onTap: () => showOptions<String>(
        title: 'Image Size',
        items: OpenAIConstants.sizes,
        labelBuilder: (v) => v,
        isSelected: (v) => s.openaiSize == v,
        onSelected: (v) => onUpdate(s.copyWith(openaiSize: v)),
      ),
    ),
    MenuSelectorItem(
      label: 'Quality',
      currentValue: s.openaiQuality == 'hd' ? 'HD' : 'Standard',
      onTap: () => showOptions<String>(
        title: 'Quality',
        items: OpenAIConstants.qualities,
        labelBuilder: (v) => v == 'hd' ? 'HD' : 'Standard',
        isSelected: (v) => s.openaiQuality == v,
        onSelected: (v) => onUpdate(s.copyWith(openaiQuality: v)),
      ),
    ),
  ];
}

/// Model-field rows for the Gemini image-gen API. Currently Gemini is
/// the default `else` branch — it shares the openai-compatible
/// connection path but uses its own aspect-ratio and resolution lists.
List<Widget> buildGeminiModelFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
  ShowOptionsCallback showOptions,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'Model',
      value: s.customModel,
      hint: 'imagen-3.0-generate-002',
      onChanged: (v) => onUpdate(s.copyWith(customModel: v)),
    ),
    MenuSelectorItem(
      label: 'Aspect Ratio',
      currentValue: s.geminiAspectRatio,
      onTap: () => showOptions<String>(
        title: 'Aspect Ratio',
        items: GeminiConstants.aspectRatios,
        labelBuilder: (v) => v,
        isSelected: (v) => s.geminiAspectRatio == v,
        onSelected: (v) => onUpdate(s.copyWith(geminiAspectRatio: v)),
      ),
    ),
    MenuSelectorItem(
      label: 'Resolution',
      currentValue: s.geminiImageSize,
      onTap: () => showOptions<String>(
        title: 'Resolution',
        items: GeminiConstants.imageSizes,
        labelBuilder: (v) => v,
        isSelected: (v) => s.geminiImageSize == v,
        onSelected: (v) => onUpdate(s.copyWith(geminiImageSize: v)),
      ),
    ),
  ];
}
