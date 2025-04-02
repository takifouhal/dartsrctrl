import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

import 'reference.dart';
import 'symbol.dart';

class DartParser {
  final String projectPath;
  final bool includeTests;
  final Logger _logger = Logger('DartParser');

  final List<Symbol> _symbols = [];
  final List<Reference> _references = [];
  final List<DartPackage> _packages = [];

  int _nextSymbolId = 1;
  final Map<Element, int> _elementToSymbolId = {};

  List<Symbol> get symbols => List.unmodifiable(_symbols);
  List<Reference> get references => List.unmodifiable(_references);
  List<DartPackage> get packages => List.unmodifiable(_packages);

  DartParser(this.projectPath, {this.includeTests = true});

  Future<void> parse() async {
    _logger.info('Starting Dart code analysis...');

    // Parse pubspec.yaml to get package information
    await _parsePackageInfo();

    // Create analysis context
    final collection = AnalysisContextCollection(
      includedPaths: [projectPath],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );

    // Get all Dart files
    final dartFiles = _findDartFiles();
    _logger.info('Found ${dartFiles.length} Dart files to analyze');

    // Process each file
    for (final file in dartFiles) {
      await _processFile(file, collection);
    }

    _logger.info(
        'Analysis complete. Found ${_symbols.length} symbols and ${_references.length} references');
  }

  Future<void> _parsePackageInfo() async {
    final pubspecFile = File(path.join(projectPath, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      _logger.warning('No pubspec.yaml found in project directory');
      return;
    }

    try {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content);

      final name = yaml['name'] as String?;
      final version = yaml['version'] as String?;

      if (name != null) {
        _packages.add(DartPackage(name, version ?? '0.0.0'));
        _logger.info('Found package: $name ${version ?? ""}');

        // Add dependencies
        final dependencies = yaml['dependencies'] as YamlMap?;
        if (dependencies != null) {
          for (final entry in dependencies.entries) {
            final depName = entry.key as String;
            String? depVersion;

            if (entry.value is String) {
              depVersion = entry.value as String;
            } else if (entry.value is YamlMap) {
              depVersion = (entry.value as YamlMap)['version'] as String?;
            }

            _packages.add(DartPackage(depName, depVersion ?? ''));
            _logger.fine('Found dependency: $depName ${depVersion ?? ""}');
          }
        }
      }
    } catch (e) {
      _logger.warning('Error parsing pubspec.yaml: $e');
    }
  }

  List<String> _findDartFiles() {
    final files = <String>[];

    void processDirectory(Directory dir) {
      try {
        for (final entity in dir.listSync()) {
          if (entity is File && entity.path.endsWith('.dart')) {
            // Skip test files if not including tests
            if (!includeTests &&
                (entity.path.contains('/test/') ||
                    entity.path.contains('_test.dart'))) {
              continue;
            }
            files.add(entity.path);
          } else if (entity is Directory) {
            // Skip certain directories
            final dirName = path.basename(entity.path);
            if (dirName == '.dart_tool' ||
                dirName == '.pub' ||
                dirName == 'build') {
              continue;
            }
            // Skip test directory if not including tests
            if (!includeTests && dirName == 'test') {
              continue;
            }
            processDirectory(entity);
          }
        }
      } catch (e) {
        _logger.warning('Error processing directory: $e');
      }
    }

    processDirectory(Directory(projectPath));
    return files;
  }

  Future<void> _processFile(
      String filePath, AnalysisContextCollection collection) async {
    try {
      final context = collection.contextFor(filePath);
      final result = await context.currentSession.getResolvedUnit(filePath);

      if (result is ResolvedUnitResult) {
        _logger.fine('Processing file: $filePath');

        // Visit the AST to extract symbols and references
        final visitor = _DartAstVisitor(this, filePath);
        result.unit.accept(visitor);
      } else {
        _logger.warning('Could not resolve file: $filePath');
      }
    } catch (e) {
      _logger.warning('Error processing file $filePath: $e');
    }
  }

  int _getSymbolId(Element element) {
    if (_elementToSymbolId.containsKey(element)) {
      return _elementToSymbolId[element]!;
    }

    final id = _nextSymbolId++;
    _elementToSymbolId[element] = id;
    return id;
  }

  void _addSymbol(Symbol symbol) {
    _symbols.add(symbol);
  }

  void _addReference(Reference reference) {
    _references.add(reference);
  }
}

class _DartAstVisitor extends RecursiveAstVisitor<void> {
  final DartParser parser;
  final String filePath;

  _DartAstVisitor(this.parser, this.filePath);

  bool _isExternalElement(Element element) {
    final library = element.library;
    if (library == null) {
      // In some edge cases, there's no library (e.g., synthetic elements).
      // We'll treat these as not external.
      return false;
    }

    // If it's in the Dart SDK, mark external
    if (library.isInSdk) {
      return true;
    }

    // If the parser recorded at least one package,
    // treat any library that isn't the first package as external.
    final mainPackageName =
        parser.packages.isNotEmpty ? parser.packages.first.name : null;
    if (mainPackageName == null || mainPackageName.isEmpty) {
      // If we don't have a main package name, treat everything except SDK as external
      return !library.isInSdk;
    }

    final uriStr = library.source.uri.toString();
    // If the library's URI doesn't contain "package:$mainPackageName/", mark it external
    if (!uriStr.contains('package:$mainPackageName/')) {
      return true;
    }

    return false;
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    // Process library
    final libraryElement = node.declaredElement?.library;
    if (libraryElement != null) {
      final libraryId = parser._getSymbolId(libraryElement);

      // Add library symbol
      final librarySymbol = Symbol(
        id: libraryId,
        name: libraryElement.name.isEmpty ? '<unnamed>' : libraryElement.name,
        kind: SymbolKind.library,
        packagePath: _getPackagePath(libraryElement),
        file: filePath,
        line: 1,
        column: 1,
        signature: '',
        external: _isExternalElement(libraryElement),
        parentId: 0,
        libraryName: libraryElement.name,
        isPrivate: false,
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(librarySymbol);

      // Add references for import directives
      for (final directive in node.directives) {
        if (directive is ImportDirective) {
          final importElement = directive.element;
          if (importElement != null) {
            final importedLibrary = importElement.importedLibrary;
            if (importedLibrary != null) {
              final importedId = parser._getSymbolId(importedLibrary);
              parser._addReference(
                Reference(
                  fromId: libraryId,
                  toId: importedId,
                  file: filePath,
                  line: directive.offset,
                  column: 0,
                  refType: ReferenceType.import,
                ),
              );
            }
          }
        }
      }
    }

    super.visitCompilationUnit(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final classElement = node.declaredElement;
    if (classElement != null) {
      final classId = parser._getSymbolId(classElement);
      final libraryElement = classElement.library;
      final libraryId = parser._getSymbolId(libraryElement);

      // Add class symbol
      final classSymbol = Symbol(
        id: classId,
        name: classElement.name,
        kind: SymbolKind.class_,
        packagePath: _getPackagePath(classElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getClassSignature(classElement),
        external: _isExternalElement(classElement),
        parentId: libraryId,
        libraryName: libraryElement.name,
        isPrivate: classElement.name.startsWith('_'),
        isStatic: false,
        isAbstract: classElement.isAbstract,
      );

      parser._addSymbol(classSymbol);

      // Add extends reference if applicable
      if (node.extendsClause != null) {
        final supertype = classElement.supertype;
        if (supertype != null) {
          final supertypeElement = supertype.element;
          final supertypeId = parser._getSymbolId(supertypeElement);

          parser._addReference(Reference(
            fromId: classId,
            toId: supertypeId,
            file: filePath,
            line: node.extendsClause!.offset,
            column: 0,
            refType: ReferenceType.extends_,
          ));
        }
      }

      // Add implements references
      if (node.implementsClause != null) {
        for (final interface in classElement.interfaces) {
          final interfaceElement = interface.element;
          final interfaceId = parser._getSymbolId(interfaceElement);

          parser._addReference(Reference(
            fromId: classId,
            toId: interfaceId,
            file: filePath,
            line: node.implementsClause!.offset,
            column: 0,
            refType: ReferenceType.implements_,
          ));
        }
      }

      // Add with (mixin) references
      if (node.withClause != null) {
        for (final mixin in classElement.mixins) {
          final mixinElement = mixin.element;
          final mixinId = parser._getSymbolId(mixinElement);

          parser._addReference(Reference(
            fromId: classId,
            toId: mixinId,
            file: filePath,
            line: node.withClause!.offset,
            column: 0,
            refType: ReferenceType.with_,
          ));
        }
      }
    }

    super.visitClassDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final methodElement = node.declaredElement;
    if (methodElement != null) {
      final methodId = parser._getSymbolId(methodElement);
      final classElement = methodElement.enclosingElement;
      final classId = parser._getSymbolId(classElement);

      // Add method symbol
      final methodSymbol = Symbol(
        id: methodId,
        name: methodElement.name,
        kind: SymbolKind.method,
        packagePath: _getPackagePath(methodElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getExecutableSignature(methodElement),
        external: _isExternalElement(methodElement),
        parentId: classId,
        libraryName: methodElement.library.name,
        isPrivate: methodElement.name.startsWith('_'),
        isStatic: methodElement.isStatic,
        isAbstract: node.isAbstract,
      );

      parser._addSymbol(methodSymbol);

      // Check for overridden methods
      if (methodElement.hasOverride) {
        // Find the parent class
        final classElement = methodElement.enclosingElement;
        if (classElement is ClassElement) {
          // Check superclasses and implemented interfaces for methods with the same name
          for (final type in [
            ...classElement.interfaces,
            if (classElement.supertype != null) classElement.supertype!,
            ...classElement.mixins,
          ]) {
            final overriddenMethod = type.element.getMethod(methodElement.name);
            if (overriddenMethod != null) {
              final baseMethodId = parser._getSymbolId(overriddenMethod);
              parser._addReference(
                Reference(
                  fromId: methodId,
                  toId: baseMethodId,
                  file: filePath,
                  line: node.offset,
                  column: 0,
                  refType: ReferenceType.override,
                ),
              );
              break; // Just add the first reference we find
            }
          }
        }
      }
    }

    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final functionElement = node.declaredElement;
    if (functionElement != null) {
      final functionId = parser._getSymbolId(functionElement);
      final libraryElement = functionElement.library;
      final libraryId = parser._getSymbolId(libraryElement);

      // Add function symbol
      final functionSymbol = Symbol(
        id: functionId,
        name: functionElement.name,
        kind: SymbolKind.function,
        packagePath: _getPackagePath(functionElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getExecutableSignature(functionElement),
        external: _isExternalElement(functionElement),
        parentId: libraryId,
        libraryName: libraryElement.name,
        isPrivate: functionElement.name.startsWith('_'),
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(functionSymbol);
    }

    super.visitFunctionDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (final variable in node.fields.variables) {
      final variableElement = variable.declaredElement;
      if (variableElement is FieldElement) {
        final fieldId = parser._getSymbolId(variableElement);
        final classElement = variableElement.enclosingElement;
        final classId = parser._getSymbolId(classElement);

        // Add field symbol
        final fieldSymbol = Symbol(
          id: fieldId,
          name: variableElement.name,
          kind: SymbolKind.field,
          packagePath: _getPackagePath(variableElement),
          file: filePath,
          line: variable.offset,
          column: 0,
          signature: _getFieldSignature(variableElement),
          external: _isExternalElement(variableElement),
          parentId: classId,
          libraryName: variableElement.library.name,
          isPrivate: variableElement.name.startsWith('_'),
          isStatic: variableElement.isStatic,
          isAbstract: false,
        );

        parser._addSymbol(fieldSymbol);
      }
    }

    super.visitFieldDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final constructorElement = node.declaredElement;
    if (constructorElement != null) {
      final constructorId = parser._getSymbolId(constructorElement);
      final classElement = constructorElement.enclosingElement;
      final classId = parser._getSymbolId(classElement);

      // Construct the full name (ClassName.constructorName or just ClassName for default)
      final fullName = constructorElement.name.isEmpty
          ? classElement.name
          : '${classElement.name}.${constructorElement.name}';

      // Add constructor symbol
      final constructorSymbol = Symbol(
        id: constructorId,
        name: fullName,
        kind: SymbolKind.constructor,
        packagePath: _getPackagePath(constructorElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getExecutableSignature(constructorElement),
        external: _isExternalElement(constructorElement),
        parentId: classId,
        libraryName: constructorElement.library.name,
        isPrivate: constructorElement.name.startsWith('_'),
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(constructorSymbol);
    }

    super.visitConstructorDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    final mixinElement = node.declaredElement;
    if (mixinElement != null) {
      final mixinId = parser._getSymbolId(mixinElement);
      final libraryElement = mixinElement.library;
      final libraryId = parser._getSymbolId(libraryElement);

      // Add mixin symbol
      final mixinSymbol = Symbol(
        id: mixinId,
        name: mixinElement.name,
        kind: SymbolKind.mixin,
        packagePath: _getPackagePath(mixinElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getMixinSignature(mixinElement),
        external: _isExternalElement(mixinElement),
        parentId: libraryId,
        libraryName: libraryElement.name,
        isPrivate: mixinElement.name.startsWith('_'),
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(mixinSymbol);

      // Add on (constraints) references
      if (node.onClause != null) {
        for (final constraint in mixinElement.superclassConstraints) {
          final constraintElement = constraint.element;
          final constraintId = parser._getSymbolId(constraintElement);

          parser._addReference(Reference(
            fromId: mixinId,
            toId: constraintId,
            file: filePath,
            line: node.onClause!.offset,
            column: 0,
            refType: ReferenceType.implements_,
          ));
        }
      }
    }

    super.visitMixinDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final extensionElement = node.declaredElement;
    if (extensionElement != null) {
      final extensionId = parser._getSymbolId(extensionElement);
      final libraryElement = extensionElement.library;
      final libraryId = parser._getSymbolId(libraryElement);

      // Add extension symbol
      final extensionSymbol = Symbol(
        id: extensionId,
        name: extensionElement.name ?? '<unnamed>',
        kind: SymbolKind.extension,
        packagePath: _getPackagePath(extensionElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getExtensionSignature(extensionElement),
        external: _isExternalElement(extensionElement),
        parentId: libraryId,
        libraryName: libraryElement.name,
        isPrivate: extensionElement.name?.startsWith('_') ?? false,
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(extensionSymbol);

      // Add reference to the extended type
      final extendedElement = extensionElement.extendedType.element;
      if (extendedElement != null) {
        final extendedId = parser._getSymbolId(extendedElement);

        parser._addReference(Reference(
          fromId: extensionId,
          toId: extendedId,
          file: filePath,
          line: node.extendedType.offset,
          column: 0,
          refType: ReferenceType.extends_,
        ));
      }
    }

    super.visitExtensionDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final enumElement = node.declaredElement;
    if (enumElement != null) {
      final enumId = parser._getSymbolId(enumElement);
      final libraryElement = enumElement.library;
      final libraryId = parser._getSymbolId(libraryElement);

      // Add enum symbol
      final enumSymbol = Symbol(
        id: enumId,
        name: enumElement.name,
        kind: SymbolKind.enum_,
        packagePath: _getPackagePath(enumElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getEnumSignature(enumElement),
        external: _isExternalElement(enumElement),
        parentId: libraryId,
        libraryName: libraryElement.name,
        isPrivate: enumElement.name.startsWith('_'),
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(enumSymbol);

      // Add enum constants
      for (final constant in node.constants) {
        final constantElement = constant.declaredElement;
        if (constantElement != null) {
          final constantId = parser._getSymbolId(constantElement);

          // Add constant symbol
          final constantSymbol = Symbol(
            id: constantId,
            name: constantElement.name,
            kind: SymbolKind.field,
            packagePath: _getPackagePath(constantElement),
            file: filePath,
            line: constant.offset,
            column: 0,
            signature: '',
            external: _isExternalElement(constantElement),
            parentId: enumId,
            libraryName: libraryElement.name,
            isPrivate: false,
            isStatic: true,
            isAbstract: false,
          );

          parser._addSymbol(constantSymbol);
        }
      }
    }

    super.visitEnumDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final variableElement = node.declaredElement;
    if (variableElement != null && variableElement is TopLevelVariableElement) {
      final variableId = parser._getSymbolId(variableElement);
      final libraryElement = variableElement.library;
      final libraryId = parser._getSymbolId(libraryElement);

      // Add variable symbol
      final variableSymbol = Symbol(
        id: variableId,
        name: variableElement.name,
        kind: SymbolKind.variable,
        packagePath: _getPackagePath(variableElement),
        file: filePath,
        line: node.offset,
        column: 0,
        signature: _getVariableSignature(variableElement),
        external: _isExternalElement(variableElement),
        parentId: libraryId,
        libraryName: libraryElement.name,
        isPrivate: variableElement.name.startsWith('_'),
        isStatic: false,
        isAbstract: false,
      );

      parser._addSymbol(variableSymbol);
    }

    super.visitVariableDeclaration(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.staticElement;
    if (element != null && !node.inDeclarationContext()) {
      // This is a reference to a symbol
      final targetId = parser._getSymbolId(element);

      // Find the enclosing declaration to determine the source of the reference
      final enclosingNode = _findEnclosingDeclaration(node);
      if (enclosingNode != null) {
        final enclosingElement = _getElementFromNode(enclosingNode);
        if (enclosingElement != null) {
          final sourceId = parser._getSymbolId(enclosingElement);

          // Determine reference type
          ReferenceType refType = ReferenceType.usage;
          if (node.parent is MethodInvocation) {
            refType = ReferenceType.call;
          }

          parser._addReference(Reference(
            fromId: sourceId,
            toId: targetId,
            file: filePath,
            line: node.offset,
            column: 0,
            refType: refType,
          ));
        }
      }
    }

    super.visitSimpleIdentifier(node);
  }

  // Helper methods

  String _getPackagePath(Element element) {
    final library = element.library;
    if (library == null) return '';

    final libraryPath = library.source.uri.toString();
    for (final package in parser.packages) {
      if (libraryPath.contains('package:${package.name}/')) {
        return package.name;
      }
    }

    return '';
  }

  String _getClassSignature(ClassElement element) {
    final buffer = StringBuffer('class ${element.name}');

    if (element.supertype != null &&
        element.supertype!.element.name != 'Object') {
      buffer.write(' extends ${element.supertype!.element.name}');
    }

    if (element.interfaces.isNotEmpty) {
      buffer.write(' implements ');
      buffer.write(element.interfaces.map((i) => i.element.name).join(', '));
    }

    if (element.mixins.isNotEmpty) {
      buffer.write(' with ');
      buffer.write(element.mixins.map((m) => m.element.name).join(', '));
    }

    return buffer.toString();
  }

  String _getExecutableSignature(ExecutableElement element) {
    final buffer = StringBuffer();

    if (element.isStatic) {
      buffer.write('static ');
    }

    if (element.returnType.toString() != 'dynamic') {
      buffer.write('${element.returnType} ');
    }

    buffer.write('${element.name}(');

    final params = element.parameters;
    if (params.isNotEmpty) {
      buffer.write(params.map((p) {
        final paramStr = StringBuffer();
        if (p.isNamed) {
          paramStr.write('{');
        } else if (p.isOptionalPositional) {
          paramStr.write('[');
        }

        if (p.type.toString() != 'dynamic') {
          paramStr.write('${p.type} ');
        }

        paramStr.write(p.name);

        if (p.defaultValueCode != null) {
          paramStr.write(' = ${p.defaultValueCode}');
        }

        if (p.isNamed) {
          paramStr.write('}');
        } else if (p.isOptionalPositional) {
          paramStr.write(']');
        }

        return paramStr.toString();
      }).join(', '));
    }

    buffer.write(')');
    return buffer.toString();
  }

  String _getFieldSignature(FieldElement element) {
    final buffer = StringBuffer();

    if (element.isStatic) {
      buffer.write('static ');
    }

    if (element.isFinal) {
      buffer.write('final ');
    } else if (element.isConst) {
      buffer.write('const ');
    }

    if (element.type.toString() != 'dynamic') {
      buffer.write('${element.type} ');
    }

    buffer.write(element.name);
    return buffer.toString();
  }

  String _getMixinSignature(MixinElement element) {
    final buffer = StringBuffer('mixin ${element.name}');

    if (element.superclassConstraints.isNotEmpty) {
      buffer.write(' on ');
      buffer.write(
          element.superclassConstraints.map((c) => c.element.name).join(', '));
    }

    if (element.interfaces.isNotEmpty) {
      buffer.write(' implements ');
      buffer.write(element.interfaces.map((i) => i.element.name).join(', '));
    }

    return buffer.toString();
  }

  String _getExtensionSignature(ExtensionElement element) {
    final buffer = StringBuffer('extension');

    if (element.name != null) {
      buffer.write(' ${element.name}');
    }

    buffer.write(' on ${element.extendedType}');

    return buffer.toString();
  }

  String _getEnumSignature(EnumElement element) {
    return 'enum ${element.name}';
  }

  String _getVariableSignature(TopLevelVariableElement element) {
    final buffer = StringBuffer();

    if (element.isFinal) {
      buffer.write('final ');
    } else if (element.isConst) {
      buffer.write('const ');
    }

    if (element.type.toString() != 'dynamic') {
      buffer.write('${element.type} ');
    }

    buffer.write(element.name);
    return buffer.toString();
  }

  AstNode? _findEnclosingDeclaration(AstNode node) {
    AstNode? current = node;
    while (current != null) {
      if (current is ClassDeclaration ||
          current is MethodDeclaration ||
          current is FunctionDeclaration ||
          current is ConstructorDeclaration ||
          current is FieldDeclaration ||
          current is MixinDeclaration ||
          current is ExtensionDeclaration ||
          current is EnumDeclaration) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  Element? _getElementFromNode(AstNode node) {
    if (node is ClassDeclaration) {
      return node.declaredElement;
    } else if (node is MethodDeclaration) {
      return node.declaredElement;
    } else if (node is FunctionDeclaration) {
      return node.declaredElement;
    } else if (node is ConstructorDeclaration) {
      return node.declaredElement;
    } else if (node is FieldDeclaration) {
      // Field declarations can have multiple variables, just return the first one
      if (node.fields.variables.isNotEmpty) {
        return node.fields.variables.first.declaredElement;
      }
    } else if (node is MixinDeclaration) {
      return node.declaredElement;
    } else if (node is ExtensionDeclaration) {
      return node.declaredElement;
    } else if (node is EnumDeclaration) {
      return node.declaredElement;
    }
    return null;
  }
}

class DartPackage {
  final String name;
  final String version;

  DartPackage(this.name, this.version);

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'version': version,
    };
  }
}
