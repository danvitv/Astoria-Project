/// Finite presentation targets. Opening a target grants no permission or effect.
enum SupportSettingsFocus {
  all,
  mode,
  connection,
  model,
  temperature,
  maxTokens,
  reasoning,
  dcp,
  privacy;

  bool includes(SupportSettingsFocus target) => this == all || this == target;
  bool get hasModelSettings =>
      this == all ||
      this == connection ||
      this == model ||
      this == temperature ||
      this == maxTokens ||
      this == reasoning ||
      this == dcp;
}
