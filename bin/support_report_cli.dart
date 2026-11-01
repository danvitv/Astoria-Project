import '../tool/support_report_cli.dart' as cli;

/// Native-asset CLI bundle entry point. Build before running key/report commands
/// so SDK build diagnostics are not mixed with the program's strict console.
Future<void> main(List<String> args) => cli.main(args);
