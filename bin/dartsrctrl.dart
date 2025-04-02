import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:dartsrctrl/src/analyzer/parser.dart';
import 'package:dartsrctrl/src/export/exporter.dart';
import 'package:logging/logging.dart';

final Logger _logger = Logger('dartsrctrl');

void main(List<String> arguments) async {
  // Configure logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    stderr.writeln('${record.level.name}: ${record.message}');
  });

  // Parse command line arguments
  final parser = ArgParser()
    ..addOption('path',
        abbr: 'p',
        defaultsTo: '.',
        help: 'Path to the Dart/Flutter project to parse')
    ..addOption('out',
        abbr: 'o',
        defaultsTo: 'output.srctrldb',
        help: 'Output file name (Sourcetrail database)')
    ..addFlag('keepjson',
        abbr: 'k', defaultsTo: false, help: 'Keep the intermediate JSON file')
    ..addFlag('includetests',
        abbr: 't', defaultsTo: true, help: 'Include test files in the analysis')
    ..addFlag('verbose',
        abbr: 'v', defaultsTo: false, help: 'Enable verbose logging')
    ..addFlag('help',
        abbr: 'h', negatable: false, help: 'Print this usage information');

  try {
    final results = parser.parse(arguments);

    if (results['help'] as bool) {
      _printUsage(parser);
      exit(0);
    }

    // Set logging level based on verbose flag
    if (results['verbose'] as bool) {
      Logger.root.level = Level.ALL;
      _logger.info('Verbose logging enabled');
    }

    // Get arguments
    final projectPath = results['path'] as String;
    var outputPath = results['out'] as String;
    final keepJson = results['keepjson'] as bool;
    final includeTests = results['includetests'] as bool;

    // Ensure output has .srctrldb extension
    if (!outputPath.endsWith('.srctrldb')) {
      outputPath += '.srctrldb';
    }

    // Validate project path
    final projectDir = Directory(projectPath);
    if (!projectDir.existsSync()) {
      _logger.severe('Project directory does not exist: $projectPath');
      exit(1);
    }

    // Determine JSON output path
    final jsonOutputPath = outputPath.replaceAll('.srctrldb', '.json');

    _logger.info('Parsing Dart/Flutter project at: $projectPath');
    _logger.info('Output will be written to: $outputPath');
    _logger.info('Include test files: $includeTests');

    // Parse the Dart/Flutter project
    _logger.info('Analyzing Dart/Flutter code...');
    final dartParser = DartParser(projectPath, includeTests: includeTests);
    await dartParser.parse();

    // Export to JSON
    _logger.info('Exporting to JSON...');
    final exporter = DartExporter();
    await exporter.exportToJson(
      jsonOutputPath,
      dartParser.symbols,
      dartParser.references,
      dartParser.packages,
    );
    _logger.info('JSON export written to: $jsonOutputPath');

    // Call Python script to generate Sourcetrail DB
    _logger.info('Generating Sourcetrail database...');
    final scriptPath = _findScriptPath();
    final result = await Process.run(
      'python3',
      [scriptPath, '--input', jsonOutputPath, '--output', outputPath],
    );

    if (result.exitCode != 0) {
      _logger.severe('Error generating Sourcetrail database:');
      _logger.severe(result.stderr);
      exit(1);
    }

    _logger.info('Sourcetrail database created at: $outputPath');

    // Clean up JSON file if not keeping it
    if (!keepJson) {
      _logger.info('Removing intermediate JSON file...');
      File(jsonOutputPath).deleteSync();
    }

    _logger.info('Done.');
  } catch (e) {
    _logger.severe('Error: $e');
    _printUsage(parser);
    exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('DartSrcCtrl - A Dart source code parser and indexer for Sourcetrail');
  print('');
  print('Usage: dartsrctrl [options]');
  print('');
  print('Options:');
  print(parser.usage);
}

String _findScriptPath() {
  // Find the generate_db.py script relative to the executable
  final scriptName = 'generate_db.py';
  final executableDir = path.dirname(Platform.script.toFilePath());

  // Try a few common locations
  final possibleLocations = [
    path.join(executableDir, scriptName),
    path.join(executableDir, '..', scriptName),
    path.join(executableDir, '..', 'lib', scriptName),
  ];

  for (final location in possibleLocations) {
    if (File(location).existsSync()) {
      return location;
    }
  }

  // Fall back to assuming it's in the same directory
  return path.join(executableDir, scriptName);
}
