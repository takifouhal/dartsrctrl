import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import '../analyzer/symbol.dart';
import '../analyzer/reference.dart';
import '../analyzer/parser.dart';

class DartExporter {
  final Logger _logger = Logger('DartExporter');

  Future<void> exportToJson(
    String jsonFilePath,
    List<Symbol> symbols,
    List<Reference> references,
    List<DartPackage> packages,
  ) async {
    _logger.info(
        'Exporting ${symbols.length} symbols and ${references.length} references to JSON');

    final data = {
      'symbols': symbols.map((s) => s.toJson()).toList(),
      'references': references.map((r) => r.toJson()).toList(),
      'packages': packages.map((p) => p.toJson()).toList(),
    };

    final file = File(jsonFilePath);

    try {
      // Create parent directory if it doesn't exist
      final dir = path.dirname(jsonFilePath);
      if (!Directory(dir).existsSync()) {
        Directory(dir).createSync(recursive: true);
      }

      // Write JSON to file with pretty printing
      final encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(data));

      _logger.info('Successfully exported data to $jsonFilePath');
    } catch (e) {
      _logger.severe('Error exporting to JSON: $e');
      rethrow;
    }
  }
}
