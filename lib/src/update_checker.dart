import 'dart:convert';
import 'dart:io';

/// Keep in step with `version:` in pubspec.yaml (the part after the plus sign).
const int sendHereBuildNumber = 75;

const _latestReleaseUrl =
    'https://api.github.com/repos/LimeBits/SendHere/releases/latest';
const releasesPageUrl = 'https://github.com/LimeBits/SendHere/releases/latest';

class AppUpdate {
  const AppUpdate({required this.tag, required this.build, required this.url});

  final String tag;
  final int build;
  final String url;
}

enum UpdateStatus { available, upToDate, failed }

/// Result of one update check. [update] is set only when [status] is
/// [UpdateStatus.available].

class UpdateCheckResult {
  const UpdateCheckResult._(this.status, this.update);

  const UpdateCheckResult.upToDate() : this._(UpdateStatus.upToDate, null);
  const UpdateCheckResult.failed() : this._(UpdateStatus.failed, null);
  UpdateCheckResult.available(AppUpdate update)
      : this._(UpdateStatus.available, update);

  final UpdateStatus status;
  final AppUpdate? update;
}

/// Reads the newest GitHub Release. Tags look like `v0.1.0-build50`.
/// Draft and pre-releases are excluded by GitHub's `releases/latest` endpoint.
class UpdateChecker {
  const UpdateChecker._();

  static int? parseBuildNumber(String tag) {
    final match = RegExp(r'build(\d+)').firstMatch(tag);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Asks GitHub for the newest release and compares its build number.
  static Future<UpdateCheckResult> check({
    int currentBuild = sendHereBuildNumber,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(_latestReleaseUrl));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'SendHere/$currentBuild');
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return const UpdateCheckResult.failed();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String? ?? '';
      final build = parseBuildNumber(tag);
      if (build == null) return const UpdateCheckResult.failed();
      if (build <= currentBuild) return const UpdateCheckResult.upToDate();
      return UpdateCheckResult.available(AppUpdate(
        tag: tag,
        build: build,
        url: json['html_url'] as String? ?? releasesPageUrl,
      ));
    } catch (_) {
      return const UpdateCheckResult.failed();
    } finally {
      client.close(force: true);
    }
  }
}
