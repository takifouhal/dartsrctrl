enum SymbolKind {
  package,
  library,
  class_,
  mixin,
  extension,
  enum_,
  function,
  method,
  constructor,
  field,
  variable,
  parameter,
  typeAlias,
}

class Symbol {
  final int id;
  final String name;
  final SymbolKind kind;
  final String packagePath;
  final String file;
  final int line;
  final int column;
  final String signature;
  final bool external;
  final int parentId;

  // Additional Dart-specific fields
  final String libraryName;
  final bool isPrivate;
  final bool isStatic;
  final bool isAbstract;

  Symbol({
    required this.id,
    required this.name,
    required this.kind,
    required this.packagePath,
    required this.file,
    required this.line,
    required this.column,
    required this.signature,
    required this.external,
    required this.parentId,
    required this.libraryName,
    required this.isPrivate,
    required this.isStatic,
    required this.isAbstract,
  });

  Map<String, dynamic> toJson() {
    return {
      'ID': id,
      'Name': name,
      'Kind': kind.toString().split('.').last,
      'PackagePath': packagePath,
      'File': file,
      'Line': line,
      'Column': column,
      'Sig': signature,
      'External': external,
      'ParentID': parentId,
      'LibraryName': libraryName,
      'IsPrivate': isPrivate,
      'IsStatic': isStatic,
      'IsAbstract': isAbstract,
    };
  }
}
