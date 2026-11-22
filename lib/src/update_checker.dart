import 'dart:convert';
import 'dart:io';

/// Keep in step with `version:` in pubspec.yaml (the part after the plus sign).
const int sendHereBuildNumber = 50;

const _latestReleaseUrl =
    'https://api.github.com/repos/LimeBits/SendHere/releases/latest';
const releasesPageUrl = 'https://github.com/LimeBits/SendHere/releases/latest';

class AppUpdate {
  const AppUpdate({required this.tag, required this.build, required this.url});

  final String tag;
  final int build;
  final String url;
}

/// Reads the newest GitHub Release. Tags look like `v0.1.0-build50`.
/// Draft and pre-releases are excluded by GitHub's `releases/latest` endpoint.
class UpdateChecker {
  const UpdateChecker._();

  static int? parseBuildNumber(String tag) {
    final match = RegExp(r'build(\d+)').firstMatch(tag);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Returns the newer release, or null when up to date or the check fails.
  /// Failures stay silent: an update check must never disturb the app.
  static Future<AppUpdate?> checkLatest({int currentBuild = sendHereBuildNumber}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(_latestReleaseUrl));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'SendHere/$currentBuild');
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String? ?? '';
      final build = parseBuildNumber(tag);
      if (build == null || build <= currentBuild) return null;
      return AppUpdate(
        tag: tag,
        build: build,
        url: json['html_url'] as String? ?? releasesPageUrl,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
