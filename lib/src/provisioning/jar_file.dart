/// Reading a jar's entries with `dart:io` alone.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The entries of a jar (a zip file), read with `dart:io` alone.
///
/// Enough of the zip format to list entry names and read an entry's text:
/// the central directory, and stored or deflated entries. No zip64 (a jar
/// over 4 GB, or with over 65 535 entries) and no encryption — neither occurs
/// in a library jar, and either throws a [FormatException].
class JarFile {
  JarFile._(this.path, this._bytes, this._entries);

  /// Reads the central directory of the jar at [path].
  ///
  /// Throws a [FormatException] for a file that is not a readable zip.
  factory JarFile.open(String path) {
    final bytes = File(path).readAsBytesSync();
    return JarFile._(path, bytes, _readCentralDirectory(bytes, path));
  }

  final String path;
  final Uint8List _bytes;
  final Map<String, _Entry> _entries;

  /// Every entry name, as stored: `com/example/Foo.class`,
  /// `META-INF/MANIFEST.MF`, directories with a trailing `/`.
  Iterable<String> get names => _entries.keys;

  bool contains(String name) => _entries.containsKey(name);

  /// The entry [name], decoded as UTF-8 (malformed bytes replaced), or `null`
  /// when there is no such entry.
  String? readText(String name) {
    final bytes = readBytes(name);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// The entry [name]'s bytes, or `null` when there is no such entry.
  Uint8List? readBytes(String name) {
    final entry = _entries[name];
    if (entry == null) return null;

    final data = ByteData.sublistView(_bytes);
    final local = entry.localHeaderOffset;
    if (data.getUint32(local, Endian.little) != _localHeaderSignature) {
      throw FormatException('bad local header for $name', path);
    }
    // The local header's own name and extra lengths, which may differ from
    // the central directory's.
    final nameLength = data.getUint16(local + 26, Endian.little);
    final extraLength = data.getUint16(local + 28, Endian.little);
    final start = local + 30 + nameLength + extraLength;
    final compressed = Uint8List.sublistView(
      _bytes,
      start,
      start + entry.compressedSize,
    );

    return switch (entry.method) {
      0 => Uint8List.fromList(compressed),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(compressed)),
      _ => throw FormatException(
        'unsupported compression method ${entry.method} for $name',
        path,
      ),
    };
  }
}

class _Entry {
  _Entry(this.method, this.compressedSize, this.localHeaderOffset);

  final int method;
  final int compressedSize;
  final int localHeaderOffset;
}

const _endOfCentralDirectorySignature = 0x06054b50;
const _centralHeaderSignature = 0x02014b50;
const _localHeaderSignature = 0x04034b50;

Map<String, _Entry> _readCentralDirectory(Uint8List bytes, String path) {
  final data = ByteData.sublistView(bytes);

  // The end-of-central-directory record is 22 bytes plus a comment of up to
  // 65 535, at the very end.
  var end = -1;
  final earliest = bytes.length - 22 - 0xffff;
  for (var i = bytes.length - 22; i >= 0 && i >= earliest; i--) {
    if (data.getUint32(i, Endian.little) == _endOfCentralDirectorySignature) {
      end = i;
      break;
    }
  }
  if (end < 0) throw FormatException('not a zip file', path);

  final count = data.getUint16(end + 10, Endian.little);
  final offset = data.getUint32(end + 16, Endian.little);
  if (count == 0xffff || offset == 0xffffffff) {
    throw FormatException('zip64 is not supported', path);
  }

  final entries = <String, _Entry>{};
  var at = offset;
  for (var i = 0; i < count; i++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != _centralHeaderSignature) {
      throw FormatException('bad central directory entry $i', path);
    }
    final flags = data.getUint16(at + 8, Endian.little);
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final localHeaderOffset = data.getUint32(at + 42, Endian.little);
    if (flags & 1 != 0) {
      throw FormatException('encrypted entries are not supported', path);
    }
    // Bit 11: the name is UTF-8; otherwise CP437, which for the ASCII names
    // of a jar is the same.
    final name = utf8.decode(
      Uint8List.sublistView(bytes, at + 46, at + 46 + nameLength),
      allowMalformed: true,
    );
    entries[name] = _Entry(method, compressedSize, localHeaderOffset);
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}
