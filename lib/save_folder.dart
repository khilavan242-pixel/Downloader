/// A destination folder the user granted access to through Android's folder
/// picker (Storage Access Framework). Works for internal storage, SD cards and
/// USB pendrives alike.
class SaveFolder {
  const SaveFolder({
    required this.uri,
    required this.name,
    required this.location,
  });

  /// Persisted `content://` tree URI. This is the identity of the folder.
  final String uri;

  /// Folder name, e.g. `Lakshya Content`.
  final String name;

  /// Parent / volume description, e.g. `primary/Documents` or `USB drive`.
  final String location;

  factory SaveFolder.fromMap(Map<dynamic, dynamic> m) => SaveFolder(
        uri: m['uri'] as String,
        name: m['name'] as String? ?? 'Folder',
        location: m['location'] as String? ?? '',
      );

  Map<String, String> toMap() => {'uri': uri, 'name': name, 'location': location};

  @override
  bool operator ==(Object other) => other is SaveFolder && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;
}
