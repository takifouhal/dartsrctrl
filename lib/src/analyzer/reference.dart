enum ReferenceType {
  usage,
  call,
  override,
  extends_,
  implements_,
  with_,
  import,
}

class Reference {
  final int fromId;
  final int toId;
  final String file;
  final int line;
  final int column;
  final ReferenceType refType;

  Reference({
    required this.fromId,
    required this.toId,
    required this.file,
    required this.line,
    required this.column,
    required this.refType,
  });

  Map<String, dynamic> toJson() {
    return {
      'FromID': fromId,
      'ToID': toId,
      'File': file,
      'Line': line,
      'Column': column,
      'RefType': refType.toString().split('.').last,
    };
  }
}
