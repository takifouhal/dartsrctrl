/// Main library for DartSrcCtrl
///
/// This library provides functionality for parsing Dart/Flutter code
/// and generating Sourcetrail databases for visualization and navigation.
library dartsrctrl;

// Remove unused imports, keep only the exports
export 'src/analyzer/parser.dart';
export 'src/analyzer/symbol.dart';
export 'src/analyzer/reference.dart';
export 'src/export/exporter.dart';
