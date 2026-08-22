import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const planContentFavoritesKey = 'plan_content_favorites_v1';
const planContentFavoriteLimit = 200;

class PlanContentFavoriteImage {
  const PlanContentFavoriteImage({
    required this.imageUrl,
    required this.thumbnailUrl,
    this.width,
    this.height,
  });

  factory PlanContentFavoriteImage.fromJson(Map<String, dynamic> json) =>
      PlanContentFavoriteImage(
        imageUrl: '${json['imageUrl'] ?? ''}',
        thumbnailUrl: '${json['thumbnailUrl'] ?? json['imageUrl'] ?? ''}',
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
      );

  final String imageUrl;
  final String thumbnailUrl;
  final int? width;
  final int? height;

  Map<String, dynamic> toJson() => {
        'imageUrl': imageUrl,
        'thumbnailUrl': thumbnailUrl,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };
}

class PlanContentFavorite {
  const PlanContentFavorite({
    required this.id,
    required this.name,
    required this.sourceId,
    required this.sourceName,
    required this.updateId,
    required this.updateTitle,
    required this.sourceUpdatedAt,
    required this.savedAt,
    required this.images,
  });

  factory PlanContentFavorite.fromJson(Map<String, dynamic> json) {
    final imageItems = json['images'] as List<dynamic>? ?? const [];
    return PlanContentFavorite(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名方案'}',
      sourceId: '${json['sourceId'] ?? ''}',
      sourceName: '${json['sourceName'] ?? ''}',
      updateId: '${json['updateId'] ?? ''}',
      updateTitle: '${json['updateTitle'] ?? ''}',
      sourceUpdatedAt: DateTime.tryParse('${json['sourceUpdatedAt'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      savedAt: DateTime.tryParse('${json['savedAt'] ?? ''}') ?? DateTime.now(),
      images: imageItems
          .whereType<Map>()
          .map((item) => PlanContentFavoriteImage.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .where((image) => image.imageUrl.trim().isNotEmpty)
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final String sourceId;
  final String sourceName;
  final String updateId;
  final String updateTitle;
  final DateTime sourceUpdatedAt;
  final DateTime savedAt;
  final List<PlanContentFavoriteImage> images;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'updateId': updateId,
        'updateTitle': updateTitle,
        'sourceUpdatedAt': sourceUpdatedAt.toIso8601String(),
        'savedAt': savedAt.toIso8601String(),
        'images': images.map((image) => image.toJson()).toList(growable: false),
      };
}

List<PlanContentFavorite> decodePlanContentFavorites(
    Iterable<String> rawItems) {
  final result = <PlanContentFavorite>[];
  for (final raw in rawItems) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) continue;
      final favorite = PlanContentFavorite.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (favorite.id.isEmpty || favorite.images.isEmpty) continue;
      result.add(favorite);
    } catch (_) {
      // Ignore a damaged local entry without hiding the user's other saves.
    }
  }
  result.sort((a, b) => b.savedAt.compareTo(a.savedAt));
  return result.take(planContentFavoriteLimit).toList(growable: false);
}

class PlanContentFavoriteStore {
  const PlanContentFavoriteStore();

  Future<List<PlanContentFavorite>> load() async {
    final preferences = await SharedPreferences.getInstance();
    return decodePlanContentFavorites(
      preferences.getStringList(planContentFavoritesKey) ?? const <String>[],
    );
  }

  Future<void> save(PlanContentFavorite favorite) async {
    final current = await load();
    final next = [
      favorite,
      ...current.where((item) => item.id != favorite.id),
    ].take(planContentFavoriteLimit).toList(growable: false);
    await replace(next);
  }

  Future<void> remove(String id) async {
    final current = await load();
    await replace(current.where((item) => item.id != id).toList());
  }

  Future<void> replace(List<PlanContentFavorite> favorites) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      planContentFavoritesKey,
      favorites
          .take(planContentFavoriteLimit)
          .map((item) => jsonEncode(item.toJson()))
          .toList(growable: false),
    );
  }
}
