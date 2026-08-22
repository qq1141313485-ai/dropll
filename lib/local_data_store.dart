import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'plan_content_favorite_store.dart';
import 'saved_scheme_store.dart';

const planFavoriteSourceIdsKey = 'plan_favorite_source_ids_v1';

enum LocalDataKind {
  contentFavorites,
  followedPlans,
  savedSchemes,
}

class LocalDataSummary {
  const LocalDataSummary({
    required this.contentFavorites,
    required this.followedPlans,
    required this.savedSchemes,
  });

  const LocalDataSummary.empty()
      : contentFavorites = 0,
        followedPlans = 0,
        savedSchemes = 0;

  final int contentFavorites;
  final int followedPlans;
  final int savedSchemes;

  int get total => contentFavorites + followedPlans + savedSchemes;
}

class LocalDataBackup {
  const LocalDataBackup({
    required this.contentFavorites,
    required this.followedPlanIds,
    required this.savedSchemes,
  });

  final List<PlanContentFavorite> contentFavorites;
  final List<String> followedPlanIds;
  final List<String> savedSchemes;

  LocalDataSummary get summary => LocalDataSummary(
        contentFavorites: contentFavorites.length,
        followedPlans: followedPlanIds.length,
        savedSchemes: savedSchemes.length,
      );
}

class LocalDataRestoreResult {
  const LocalDataRestoreResult({
    required this.addedContentFavorites,
    required this.addedFollowedPlans,
    required this.addedSavedSchemes,
  });

  final int addedContentFavorites;
  final int addedFollowedPlans;
  final int addedSavedSchemes;

  int get totalAdded =>
      addedContentFavorites + addedFollowedPlans + addedSavedSchemes;
}

class LocalDataStore {
  const LocalDataStore();

  static const backupFormat = 'caimaster-local-data';
  static const backupVersion = 1;

  Future<LocalDataSummary> loadSummary() async {
    final preferences = await SharedPreferences.getInstance();
    final contentFavorites = await const PlanContentFavoriteStore().load();
    final savedSchemes = await const SavedSchemeStore().load();
    final followedPlans =
        preferences.getStringList(planFavoriteSourceIdsKey) ?? const <String>[];
    return LocalDataSummary(
      contentFavorites: contentFavorites.length,
      followedPlans: followedPlans.toSet().length,
      savedSchemes: savedSchemes.length,
    );
  }

  Future<void> clear(LocalDataKind kind) async {
    switch (kind) {
      case LocalDataKind.contentFavorites:
        await const PlanContentFavoriteStore().replace(const []);
        return;
      case LocalDataKind.followedPlans:
        final preferences = await SharedPreferences.getInstance();
        await preferences.remove(planFavoriteSourceIdsKey);
        return;
      case LocalDataKind.savedSchemes:
        await const SavedSchemeStore().replace(const []);
        return;
    }
  }

  Future<String> createBackupJson({DateTime? exportedAt}) async {
    final preferences = await SharedPreferences.getInstance();
    final contentFavorites = await const PlanContentFavoriteStore().load();
    final savedSchemes = await const SavedSchemeStore().load(now: exportedAt);
    final followedPlanIds = _normalizeIds(
      preferences.getStringList(planFavoriteSourceIdsKey) ?? const <String>[],
    );
    return const JsonEncoder.withIndent('  ').convert({
      'format': backupFormat,
      'version': backupVersion,
      'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
      'contentFavorites': contentFavorites
          .map((favorite) => favorite.toJson())
          .toList(growable: false),
      'followedPlanIds': followedPlanIds,
      'savedSchemes': savedSchemes,
    });
  }

  LocalDataBackup decodeBackup(String raw, {DateTime? now}) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('文件不是有效的 JSON 备份');
    }
    if (decoded is! Map || decoded['format'] != backupFormat) {
      throw const FormatException('这不是球镜本机数据备份');
    }
    if (decoded['version'] != backupVersion) {
      throw const FormatException('备份版本暂不支持，请先更新 App');
    }
    final favoritesRaw = decoded['contentFavorites'];
    final followedRaw = decoded['followedPlanIds'];
    final schemesRaw = decoded['savedSchemes'];
    if (favoritesRaw is! List || followedRaw is! List || schemesRaw is! List) {
      throw const FormatException('备份内容不完整');
    }

    final favoriteJson = favoritesRaw
        .whereType<Map>()
        .map((item) => jsonEncode(Map<String, dynamic>.from(item)));
    final favorites = <PlanContentFavorite>[];
    final favoriteIds = <String>{};
    for (final favorite in decodePlanContentFavorites(favoriteJson)) {
      if (favoriteIds.add(favorite.id)) favorites.add(favorite);
    }
    final followedPlanIds = _normalizeIds(followedRaw.whereType<String>());
    final savedSchemeIds = <String>{};
    final savedSchemes = retainRecentSavedSchemes(
      schemesRaw
          .whereType<String>()
          .where((scheme) => savedSchemeIds.add(savedSchemeIdentity(scheme))),
      now: now ?? DateTime.now(),
    );
    return LocalDataBackup(
      contentFavorites: favorites,
      followedPlanIds: followedPlanIds,
      savedSchemes: savedSchemes,
    );
  }

  Future<LocalDataRestoreResult> mergeBackup(LocalDataBackup backup) async {
    final preferences = await SharedPreferences.getInstance();
    final currentFavorites = await const PlanContentFavoriteStore().load();
    final favoriteIds = currentFavorites.map((item) => item.id).toSet();
    final addedFavorites = backup.contentFavorites
        .where((item) => favoriteIds.add(item.id))
        .take(planContentFavoriteLimit - currentFavorites.length)
        .toList(growable: false);
    await const PlanContentFavoriteStore().replace(
      [...currentFavorites, ...addedFavorites],
    );

    final currentFollowed = _normalizeIds(
      preferences.getStringList(planFavoriteSourceIdsKey) ?? const <String>[],
    );
    final followedIds = currentFollowed.toSet();
    final addedFollowed = backup.followedPlanIds
        .where((id) => followedIds.add(id))
        .toList(growable: false);
    await preferences.setStringList(
      planFavoriteSourceIdsKey,
      [...currentFollowed, ...addedFollowed],
    );

    final currentSchemes = await const SavedSchemeStore().load();
    final schemeValues = currentSchemes.map(savedSchemeIdentity).toSet();
    final addedSchemes = backup.savedSchemes
        .where((scheme) => schemeValues.add(savedSchemeIdentity(scheme)))
        .take(savedFootballSchemeLimit - currentSchemes.length)
        .toList(growable: false);
    await const SavedSchemeStore().replace(
      [...currentSchemes, ...addedSchemes]
          .take(savedFootballSchemeLimit)
          .toList(growable: false),
    );

    return LocalDataRestoreResult(
      addedContentFavorites: addedFavorites.length,
      addedFollowedPlans: addedFollowed.length,
      addedSavedSchemes: addedSchemes.length,
    );
  }

  static List<String> _normalizeIds(Iterable<String> values) => values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
