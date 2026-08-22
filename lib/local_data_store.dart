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
}

class LocalDataStore {
  const LocalDataStore();

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
}
