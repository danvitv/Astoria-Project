// Studio's original and POST-cleaner versions share one outer variation.
// Both belong to the blue nested Studio level; ordinary outer swipes use the
// neutral switcher. A metadata-only update must not hide nested navigation.
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
