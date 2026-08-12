/// Extracts a YouTube video ID from arbitrary shared text.
///
/// Handles watch/youtu.be/shorts/live/embed URLs, `si=`/`t=` junk params,
/// surrounding text ("Check this out https://youtu.be/... !"), and bare IDs.
library;

final RegExp _urlRe = RegExp(r'https?://\S+');
final RegExp _idRe = RegExp(r'^[\w-]{11}$');

String? extractYoutubeVideoId(String text) {
  for (final match in _urlRe.allMatches(text)) {
    // Strip trailing punctuation that often rides along in shared text.
    final url = match.group(0)!.replaceAll(RegExp(r'''[.,!?;:)\]'"]+$'''), '');
    final id = _idFromUrl(url);
    if (id != null) return id;
  }
  final trimmed = text.trim();
  if (_idRe.hasMatch(trimmed)) return trimmed;
  return null;
}

String? _idFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  const ytHosts = {
    'youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtube-nocookie.com',
    'youtu.be',
  };
  if (!ytHosts.contains(host)) return null;

  String? candidate;
  if (host == 'youtu.be') {
    candidate = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
  } else if (uri.queryParameters.containsKey('v')) {
    candidate = uri.queryParameters['v'];
  } else {
    final segs = uri.pathSegments;
    if (segs.length >= 2 &&
        const {'shorts', 'live', 'embed', 'v'}.contains(segs[0])) {
      candidate = segs[1];
    }
  }
  if (candidate != null && _idRe.hasMatch(candidate)) return candidate;
  return null;
}
