// ignore_for_file: avoid_web_libraries_in_flutter

// ignore: deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

bool downloadImageUrl(String url, {required String fileName}) {
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..target = '_blank'
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  return true;
}

bool downloadImageBytes(
  Uint8List bytes, {
  required String mimeType,
  required String fileName,
}) {
  final blob = html.Blob(<Object>[bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 1),
    () => html.Url.revokeObjectUrl(url),
  );
  return true;
}
