// Studio's original and POST-cleaner versions share one outer variation.
// Regression: both were painted blue, and a metadata-only update hid the
// nested switcher even though both versions were still stored.
export const studioSwipes = {
  original: 'She set the lamp down.',
  cleaned: 'She placed the lamp on the table.',
  kinds: ['final', 'cleaned'],
  failed: 'The Main Writer request failed.',
  finalOnly: {
    label: 'Только финал',
    title: 'Перезапустить только основного писателя с сохранёнными результатами контроллеров и Think',
  },
};
