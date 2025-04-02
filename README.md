# DartSrcCtrl

A Dart source code parser and indexer for Sourcetrail, inspired by [gosrctrl](https://github.com/takifouhal/gosrctrl).

## Overview

DartSrcCtrl is a tool that parses Dart and Flutter source code and generates a Sourcetrail database for visualization and navigation. It extracts symbols (classes, methods, functions, etc.) and references (usages, calls, inheritance, etc.) from Dart code and exports them to a format that can be imported into Sourcetrail.

## Features

- Parse Dart and Flutter source code
- Extract symbols (classes, methods, functions, etc.)
- Extract references (usages, calls, inheritance, etc.)
- Support for Dart-specific features (mixins, extensions, etc.)
- Export to JSON format
- Generate Sourcetrail database

## Installation

### Prerequisites

- Dart SDK (2.17.0 or later)
- Python 3.6 or later
- Numbat Python package (`pip install numbat`)

### Installation Steps

1. Clone the repository
2. Run `dart pub get` to install dependencies
3. Make sure the `generate_db.py` script is in the same directory as the executable or in a location accessible to the tool

## Usage

```bash
dart run bin/dartsrctrl.dart --path /path/to/dart/project --out output.srctrldb
```

### Command-line Options

- `--path` or `-p`: Path to the Dart/Flutter project to parse (default: current directory)
- `--out` or `-o`: Output file name (Sourcetrail database) (default: `output.srctrldb`)
- `--keepjson` or `-k`: Keep the intermediate JSON file (default: false)
- `--includetests` or `-t`: Include test files in the analysis (default: true)
- `--verbose` or `-v`: Enable verbose logging for debugging (default: false)
- `--help` or `-h`: Print usage information

The `--verbose` flag is particularly useful for troubleshooting database generation issues, as it provides detailed logging of the process.

## Architecture

DartSrcCtrl consists of several components:

1. **CLI Application**: Handles command-line arguments and orchestrates the workflow
2. **Dart Parser**: Analyzes Dart code and extracts symbols and references
3. **JSON Exporter**: Serializes the extracted data to JSON
4. **Database Generator**: Converts the JSON data into a Sourcetrail database

### Workflow

1. User runs DartSrcCtrl with a path to a Dart/Flutter project
2. DartSrcCtrl parses the Dart code and extracts symbols and references
3. The extracted data is exported to a JSON file
4. The Python script is called to generate a Sourcetrail database
5. The JSON file is removed (unless `--keepjson` is specified)

## Development

### Project Structure

```
dartsrctrl/
├── bin/
│   └── dartsrctrl.dart     # Main entry point
├── lib/
│   ├── dartsrctrl.dart     # Main library file
│   └── src/
│       ├── analyzer/       # Dart code analysis
│       │   ├── parser.dart # Core parsing logic
│       │   ├── symbol.dart # Symbol data structures
│       │   └── reference.dart # Reference data structures
│       └── export/
│           └── exporter.dart # JSON export functionality
├── generate_db.py          # Python script for database generation
└── pubspec.yaml            # Dart package configuration
```

### Dependencies

- `analyzer`: For parsing and analyzing Dart code
- `args`: For command-line argument parsing
- `path`: For file path manipulation
- `yaml`: For parsing pubspec.yaml files
- `collection`: For utility collection functions
- `logging`: For logging functionality

### Python Dependencies

- `numbat`: For generating Sourcetrail databases (version 0.2.2 or later)
- `pathlib`: For file path manipulation in Python
- `logging`: For structured logging in the database generation script

## Limitations

- The current implementation may not handle all edge cases in complex Dart code
- Some advanced Dart features might not be fully supported
- While the Sourcetrail database generation has been improved for compatibility with the Numbat library, some visualization aspects may still require further refinement

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgements

- [gosrctrl](https://github.com/takifouhal/gosrctrl) for the original inspiration
- [Sourcetrail](https://www.sourcetrail.com/) for the visualization tool
- [Dart Analyzer](https://pub.dev/packages/analyzer) for the Dart parsing capabilities
