import 'package:url_launcher/url_launcher.dart';

Future<void> installUpdate(Uri? pageUri) async {
  if (pageUri != null) await launchUrl(pageUri);
}
