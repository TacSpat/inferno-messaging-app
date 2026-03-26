/// Returns a valid HTTP/HTTPS URL or null.
/// Filters out Rails-local relative paths like "/cached_assets/..."
/// that can't be loaded by NetworkImage.
String? validImageUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  return null;
}

/// Returns an ImageProvider for a URL, or null if invalid.
/// Use this instead of NetworkImage directly to avoid crashes from relative paths.
