import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

const _favoriteKey = 'plan_favorite_source_ids_v1';

class PlanCenterPage extends StatefulWidget {
  const PlanCenterPage({super.key});

  @override
  State<PlanCenterPage> createState() => _PlanCenterPageState();
}

class _PlanCenterPageState extends State<PlanCenterPage> {
  final CaiApiClient _client = CaiApiClient();
  Set<String> _favoriteIds = <String>{};
  List<PlanSource> _sources = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _remoteStatusMessage;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted && _sources.isEmpty && !_loading) {
      setState(() => _loading = true);
    }
    var favoriteIds = _favoriteIds;
    var sources = _sources;
    String? remoteStatusMessage;
    try {
      final prefs = await SharedPreferences.getInstance();
      favoriteIds =
          (prefs.getStringList(_favoriteKey) ?? const <String>[]).toSet();
      final recentBody = await _client.fetchRecentPlans(limit: 6);
      sources = _planSourcesFromBody(recentBody);
      if (sources.isNotEmpty && favoriteIds.isNotEmpty) {
        final favoriteBody = await _client.fetchPlans(
          ids: favoriteIds.toList(growable: false),
          limit: 50,
        );
        final favorites = _planSourcesFromBody(favoriteBody);
        var migratedFavorites = false;
        for (final source in favorites) {
          final legacyFavorites = source.aliasIds.intersection(favoriteIds);
          if (legacyFavorites.isEmpty) continue;
          favoriteIds
            ..removeAll(legacyFavorites)
            ..add(source.id);
          migratedFavorites = true;
        }
        if (migratedFavorites) {
          await prefs.setStringList(_favoriteKey, favoriteIds.toList()..sort());
        }
        final merged = <String, PlanSource>{
          for (final source in sources) source.id: source,
          for (final source in favorites) source.id: source,
        };
        sources = merged.values.toList(growable: false)
          ..sort(
            (a, b) =>
                b.latestUpdate.updatedAt.compareTo(a.latestUpdate.updatedAt),
          );
      }
    } catch (error) {
      remoteStatusMessage = _planRemoteStatusMessage(error);
    }
    _refreshing = false;
    if (!mounted) return;
    setState(() {
      _favoriteIds = favoriteIds;
      _sources = sources;
      _loading = false;
      _remoteStatusMessage = remoteStatusMessage;
    });
  }

  Future<void> _reloadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favoriteIds =
        (prefs.getStringList(_favoriteKey) ?? const <String>[]).toSet();
    if (!mounted) return;
    setState(() => _favoriteIds = favoriteIds);
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final favorites = sources
        .where((source) => _favoriteIds.contains(source.id))
        .toList()
      ..sort((a, b) {
        final todayOrder =
            (b.updatedToday == true ? 1 : 0) - (a.updatedToday == true ? 1 : 0);
        if (todayOrder != 0) return todayOrder;
        return b.latestUpdate.updatedAt.compareTo(a.latestUpdate.updatedAt);
      });
    final visibleFavorites = favorites.take(2).toList(growable: false);
    final recentUpdates = sources
        .map((source) => _PlanUpdateEntry(source, source.latestUpdate))
        .toList(growable: false)
      ..sort((a, b) => b.update.updatedAt.compareTo(a.update.updatedAt));
    final visibleRecent = recentUpdates.take(6).toList(growable: false);

    return Scaffold(
      backgroundColor: const Color(0xfff6f7f8),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: const Color(0xff079669),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '计划',
                      style: TextStyle(
                        fontSize: 26,
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                        color: Color(0xff111315),
                      ),
                    ),
                    if (_remoteStatusMessage != null && sources.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _PlanDataSourceNotice(
                        message: _remoteStatusMessage!,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_loading && sources.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (sources.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _PlanEmptyState(
                  hasError: _remoteStatusMessage != null,
                  onRetry: _refresh,
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  title:
                      favorites.isEmpty ? '我的收藏' : '我的收藏  ${favorites.length}个',
                  actionText: favorites.isEmpty ? '' : '管理收藏',
                  onAction: favorites.isEmpty ? null : _openFavorites,
                ),
              ),
              SliverToBoxAdapter(
                child: favorites.isEmpty
                    ? _EmptyFavorites(onTap: _openAllPlans)
                    : Container(
                        color: Colors.white,
                        child: Column(
                          children: [
                            for (var index = 0;
                                index < visibleFavorites.length;
                                index++) ...[
                              _FavoriteStatusRow(
                                source: visibleFavorites[index],
                                onTap: () =>
                                    _openDetail(visibleFavorites[index]),
                              ),
                              if (index != visibleFavorites.length - 1)
                                const Divider(
                                  height: 1,
                                  indent: 18,
                                  endIndent: 18,
                                  color: Color(0xffe8ebea),
                                ),
                            ],
                            if (favorites.length > visibleFavorites.length)
                              _MoreFavoritesRow(
                                count:
                                    favorites.length - visibleFavorites.length,
                                onTap: _openFavorites,
                              ),
                          ],
                        ),
                      ),
              ),
              SliverToBoxAdapter(
                child: _SectionHeader(
                  title: '最近更新',
                  actionText: '全部计划',
                  onAction: _openAllPlans,
                ),
              ),
              SliverList.separated(
                itemCount: visibleRecent.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final entry = visibleRecent[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: _TodayUpdateCard(
                      source: entry.source,
                      update: entry.update,
                      onTap: () => _openDetail(entry.source),
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(
                child: SizedBox(height: 22),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openDetail(PlanSource source) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanDetailPage(source: source),
      ),
    );
    await _reloadFavorites();
  }

  Future<void> _openAllPlans() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const AllPlansPage(),
      ),
    );
    await _reloadFavorites();
  }

  Future<void> _openFavorites() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const AllPlansPage(favoriteOnly: true),
      ),
    );
    await _reloadFavorites();
  }
}

class AllPlansPage extends StatefulWidget {
  const AllPlansPage({this.favoriteOnly = false, super.key});

  final bool favoriteOnly;

  @override
  State<AllPlansPage> createState() => _AllPlansPageState();
}

class _AllPlansPageState extends State<AllPlansPage> {
  static const _pageSize = 20;
  final CaiApiClient _client = CaiApiClient();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchTimer;
  List<PlanSource> _sources = const [];
  String _keyword = '';
  bool _loading = false;
  bool _hasMore = false;
  bool _loadMoreFailed = false;
  String? _remoteStatusMessage;
  String _activity = 'recent';
  int _nextOffset = 0;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadNextPage);
    _loadPage(reset: true);
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _client.close();
    _searchController.dispose();
    _scrollController
      ..removeListener(_loadNextPage)
      ..dispose();
    super.dispose();
  }

  void _loadNextPage() {
    if (!_scrollController.hasClients ||
        _scrollController.position.extentAfter > 240 ||
        _loadMoreFailed) {
      return;
    }
    if (_hasMore && !_loading) _loadPage();
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (!reset && _loading) return;
    if (!reset && !_hasMore) return;
    final generation = reset ? ++_loadGeneration : _loadGeneration;
    final query = _keyword;
    setState(() {
      _loading = true;
      if (reset) _loadMoreFailed = false;
    });
    final offset = reset ? 0 : _nextOffset;
    try {
      var ids = const <String>[];
      if (widget.favoriteOnly) {
        final prefs = await SharedPreferences.getInstance();
        ids = prefs.getStringList(_favoriteKey) ?? const <String>[];
        if (ids.isEmpty) {
          if (!mounted || generation != _loadGeneration) return;
          setState(() {
            _sources = const [];
            _hasMore = false;
            _nextOffset = 0;
            _loading = false;
            _loadMoreFailed = false;
            _remoteStatusMessage = null;
          });
          return;
        }
      }
      final body = await _client.fetchPlans(
        ids: ids,
        query: query,
        activity: widget.favoriteOnly ? 'all' : _activity,
        limit: _pageSize,
        offset: offset,
      );
      final incoming = _planSourcesFromBody(body);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _sources = reset ? incoming : [..._sources, ...incoming];
        _hasMore = body['hasMore'] == true;
        _nextOffset = (body['nextOffset'] as num?)?.toInt() ?? _sources.length;
        _loading = false;
        _loadMoreFailed = false;
        _remoteStatusMessage = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (reset && _sources.isEmpty) {
          _sources = const [];
        }
        if (reset) {
          _remoteStatusMessage = _planRemoteStatusMessage(error);
          if (_sources.isEmpty) _hasMore = false;
        } else {
          _loadMoreFailed = true;
          _remoteStatusMessage = null;
        }
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value;
      _sources = const [];
      _hasMore = false;
      _loading = true;
      _loadMoreFailed = false;
      _remoteStatusMessage = null;
    });
    _searchTimer?.cancel();
    _searchTimer = Timer(
      const Duration(milliseconds: 350),
      () => _loadPage(reset: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff6f7f8),
      appBar: AppBar(
        title: Text(widget.favoriteOnly ? '我的收藏' : '全部计划'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索计划名称',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _keyword.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xffe2e6e4)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xffe2e6e4)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xff079669),
                    width: 1.4,
                  ),
                ),
              ),
            ),
          ),
          if (!widget.favoriteOnly && _keyword.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'recent',
                      label: Text('近期活跃'),
                    ),
                    ButtonSegment(
                      value: 'history',
                      label: Text('历史计划'),
                    ),
                  ],
                  selected: {_activity},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    final activity = selection.first;
                    if (activity == _activity) return;
                    setState(() => _activity = activity);
                    _loadPage(reset: true);
                  },
                ),
              ),
            ),
          if (_remoteStatusMessage != null && _sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: _PlanDataSourceNotice(
                message: _remoteStatusMessage!,
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadPage(reset: true),
              color: const Color(0xff079669),
              child: _sources.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.55,
                          child: Center(
                            child: _loading
                                ? const CircularProgressIndicator()
                                : _PlanEmptyState(
                                    hasError: _remoteStatusMessage != null,
                                    onRetry: () => _loadPage(reset: true),
                                    noContentText: _keyword.trim().isNotEmpty
                                        ? '没有找到相关计划'
                                        : widget.favoriteOnly
                                            ? '还没有收藏计划'
                                            : _activity == 'history'
                                                ? '没有找到历史计划'
                                                : '没有找到近期计划',
                                  ),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                      itemCount: _sources.length +
                          (_hasMore || _loadMoreFailed ? 1 : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        if (index == _sources.length) {
                          if (_loadMoreFailed) {
                            return Padding(
                              padding: const EdgeInsets.all(12),
                              child: Center(
                                child: TextButton.icon(
                                  onPressed: () {
                                    setState(() => _loadMoreFailed = false);
                                    _loadPage();
                                  },
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重试加载'),
                                ),
                              ),
                            );
                          }
                          return const Padding(
                            padding: EdgeInsets.all(18),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        final source = _sources[index];
                        return _PlanSourceRow(
                          source: source,
                          historical:
                              !widget.favoriteOnly && _activity == 'history',
                          onTap: () => _openPlan(source),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openPlan(PlanSource source) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanDetailPage(source: source),
      ),
    );
    if (widget.favoriteOnly) await _loadPage(reset: true);
  }
}

class PlanDetailPage extends StatefulWidget {
  const PlanDetailPage({required this.source, super.key});

  final PlanSource source;

  @override
  State<PlanDetailPage> createState() => _PlanDetailPageState();
}

class _PlanDetailPageState extends State<PlanDetailPage> {
  final CaiApiClient _client = CaiApiClient();
  bool _favorite = false;
  bool _recentOnly = false;
  bool _loading = false;
  bool _hasMore = false;
  int _nextOffset = 0;
  int _loadGeneration = 0;
  int _visibleUpdateCount = 10;
  List<PlanUpdate> _remoteUpdates = const [];
  String? _loadErrorMessage;

  @override
  void initState() {
    super.initState();
    _loadFavorite();
    if (widget.source.isRemote) _loadUpdates(reset: true);
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadFavorite() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_favoriteKey) ?? const <String>[];
    if (!mounted) return;
    setState(() => _favorite = ids.contains(widget.source.id));
  }

  Future<void> _toggleFavorite() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_favoriteKey) ?? <String>[];
    final nextIds = ids.toSet();
    if (_favorite) {
      nextIds.remove(widget.source.id);
    } else {
      nextIds.add(widget.source.id);
    }
    await prefs.setStringList(_favoriteKey, nextIds.toList()..sort());
    if (!mounted) return;
    setState(() => _favorite = !_favorite);
  }

  Future<void> _loadUpdates({bool reset = false}) async {
    if (!widget.source.isRemote || (_loading && !reset)) return;
    if (!reset && !_hasMore) return;
    final generation = reset ? ++_loadGeneration : _loadGeneration;
    setState(() {
      _loading = true;
      _loadErrorMessage = null;
    });
    final offset = reset ? 0 : _nextOffset;
    try {
      final body = await _client.fetchPlanUpdates(
        widget.source.id,
        days: _recentOnly ? 7 : null,
        limit: 10,
        offset: offset,
      );
      final items = body['items'] as List<dynamic>? ?? const [];
      final incoming = items
          .whereType<Map<String, dynamic>>()
          .map(PlanUpdate.fromJson)
          .where((update) => update.images.isNotEmpty)
          .toList(growable: false);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _remoteUpdates = reset ? incoming : [..._remoteUpdates, ...incoming];
        _hasMore = body['hasMore'] == true;
        _nextOffset =
            (body['nextOffset'] as num?)?.toInt() ?? _remoteUpdates.length;
        _loading = false;
        _loadErrorMessage = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadErrorMessage = _planRemoteStatusMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final now = DateTime.now();
    final cutoff = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final filteredUpdates = source.isRemote
        ? _remoteUpdates
        : source.activeUpdates
            .where(
              (update) => !_recentOnly || !update.updatedAt.isBefore(cutoff),
            )
            .toList(growable: false);
    final updates = source.isRemote
        ? filteredUpdates
        : filteredUpdates.take(_visibleUpdateCount).toList(growable: false);
    return Scaffold(
      backgroundColor: const Color(0xfff6f7f8),
      appBar: AppBar(
        title: Text(source.name),
        actions: [
          IconButton(
            tooltip: _favorite ? '取消收藏' : '收藏',
            onPressed: _toggleFavorite,
            icon: Icon(
              _favorite ? Icons.star_rounded : Icons.star_border_rounded,
              color: _favorite ? const Color(0xfff2a400) : null,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            source.isRemote ? _loadUpdates(reset: true) : Future<void>.value(),
        color: const Color(0xff079669),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          children: [
            _PlanIdentityCard(source: source),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('全部更新')),
                ButtonSegment(value: true, label: Text('最近7天')),
              ],
              selected: {_recentOnly},
              showSelectedIcon: false,
              onSelectionChanged: (values) {
                setState(() {
                  _recentOnly = values.first;
                  _visibleUpdateCount = 10;
                  if (source.isRemote) _remoteUpdates = const [];
                });
                if (source.isRemote) _loadUpdates(reset: true);
              },
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(height: 16),
            if (updates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : _loadErrorMessage != null
                          ? _PlanLoadError(
                              message: _loadErrorMessage!,
                              onRetry: () => _loadUpdates(reset: true),
                            )
                          : Text(
                              _recentOnly ? '最近7天暂无更新' : '暂无更新内容',
                              style: const TextStyle(color: Color(0xff858b91)),
                            ),
                ),
              ),
            for (var index = 0; index < updates.length; index++) ...[
              if (index == 0 ||
                  !_isSameDay(
                    updates[index].updatedAt,
                    updates[index - 1].updatedAt,
                  ))
                _DateGroupHeader(date: updates[index].updatedAt),
              _PlanUpdateBlock(
                source: source,
                update: updates[index],
                onImageTap: (imageIndex) =>
                    _openImageViewer(updates[index], imageIndex),
              ),
              const SizedBox(height: 14),
            ],
            if ((source.isRemote && _hasMore) ||
                (!source.isRemote && updates.length < filteredUpdates.length))
              TextButton(
                onPressed: _loading
                    ? null
                    : source.isRemote
                        ? _loadUpdates
                        : () => setState(
                              () => _visibleUpdateCount += 10,
                            ),
                child: Text(_loading ? '正在加载' : '加载更早更新'),
              ),
            if (updates.isNotEmpty && _loadErrorMessage != null)
              _PlanLoadError(
                message: _loadErrorMessage!,
                onRetry: _loadUpdates,
                compact: true,
              ),
          ],
        ),
      ),
    );
  }

  void _openImageViewer(PlanUpdate update, int imageIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanImageViewerPage(
          source: widget.source,
          update: update,
          initialIndex: imageIndex,
        ),
      ),
    );
  }
}

class _PlanLoadError extends StatelessWidget {
  const _PlanLoadError({
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 8 : 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xff858b91)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

class PlanImageViewerPage extends StatefulWidget {
  const PlanImageViewerPage({
    required this.source,
    required this.update,
    required this.initialIndex,
    super.key,
  });

  final PlanSource source;
  final PlanUpdate update;
  final int initialIndex;

  @override
  State<PlanImageViewerPage> createState() => _PlanImageViewerPageState();
}

class _PlanImageViewerPageState extends State<PlanImageViewerPage> {
  late final PageController _pageController;
  late final List<GlobalKey> _imageKeys;
  late int _currentIndex;
  bool _saving = false;

  PlanImage get _currentImage => widget.update.images[_currentIndex];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _imageKeys = List<GlobalKey>.generate(
      widget.update.images.length,
      (_) => GlobalKey(),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff101214),
      appBar: AppBar(
        backgroundColor: const Color(0xff101214),
        foregroundColor: Colors.white,
        title: Text('${widget.source.name} 计划图片'),
        actions: [
          IconButton(
            tooltip: '保存图片',
            onPressed: _saving ? null : _saveImage,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.update.images.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) {
                final image = widget.update.images[index];
                return Center(
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 86),
                      child: RepaintBoundary(
                        key: _imageKeys[index],
                        child: _PlanImageCard(
                          image: image,
                          update: widget.update,
                          large: true,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 18,
              child: Column(
                children: [
                  Text(
                    '${_currentIndex + 1} / ${widget.update.images.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_formatShortDate(widget.update.updatedAt)} '
                    '${_formatTime(widget.update.updatedAt)} · '
                    '由 ${widget.source.uploaderName} 上传',
                    style: const TextStyle(
                      color: Color(0xffc2c6c9),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      late final Uint8List bytes;
      var extension = 'png';
      var mimeType = 'image/png';
      if (_currentImage.isRemote) {
        final response = await http
            .get(Uri.parse(_currentImage.imageUrl!))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          throw StateError('原图下载失败');
        }
        bytes = response.bodyBytes;
        extension = 'jpg';
        mimeType = response.headers['content-type'] ?? 'image/jpeg';
      } else {
        final boundary = _imageKeys[_currentIndex]
            .currentContext
            ?.findRenderObject() as RenderRepaintBoundary?;
        if (boundary == null) {
          throw StateError('图片尚未准备好');
        }
        final renderedImage = await boundary.toImage(pixelRatio: 3);
        final byteData = await renderedImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        final renderedBytes = byteData?.buffer.asUint8List();
        if (renderedBytes == null) {
          throw StateError('图片生成失败');
        }
        bytes = renderedBytes;
      }
      final safeName = '${widget.source.name}_${_currentImage.title}'
          .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      final fileName = '$safeName.$extension';
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: mimeType,
              name: fileName,
            ),
          ],
          fileNameOverrides: [fileName],
          subject: '${widget.source.name}计划图片',
          text: '${widget.source.name}计划图片',
        ),
      );
      if (result.status == ShareResultStatus.unavailable) {
        throw StateError('系统保存服务不可用');
      }
      if (!mounted || result.status != ShareResultStatus.success) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片操作已完成')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片保存失败，请稍后再试')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        height: 70,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffe5e8e6)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.star_border_rounded,
              color: Color(0xff8a9096),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '还没有收藏计划',
                style: TextStyle(
                  color: Color(0xff737a80),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: onTap,
              child: const Text('去看看'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteStatusRow extends StatelessWidget {
  const _FavoriteStatusRow({
    required this.source,
    required this.onTap,
  });

  final PlanSource source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final latest = source.latestUpdate;
    final updatedToday = source.updatedToday ?? _isToday(latest.updatedAt);
    final statusText = updatedToday
        ? '新增${latest.displayImageCount}张 · ${_formatTime(latest.updatedAt)}'
        : _pastUpdateStatus(latest.updatedAt);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: updatedToday
                      ? const Color(0xff079669)
                      : const Color(0xffaeb3b1),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xff17191c),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: updatedToday
                        ? const Color(0xff079669)
                        : const Color(0xff858b91),
                    fontWeight:
                        updatedToday ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: Color(0xffa5aaa8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreFavoritesRow extends StatelessWidget {
  const _MoreFavoritesRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xffe8ebea))),
        ),
        child: Row(
          children: [
            const SizedBox(width: 17),
            Expanded(
              child: Text(
                '还有$count个收藏',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xff858b91),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Text(
              '查看',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xff079669),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Color(0xff079669),
            ),
          ],
        ),
      ),
    );
  }
}

String _recentUpdateLabel(PlanUpdate update) {
  final count = update.displayImageCount;
  if (_isToday(update.updatedAt)) {
    return '${_formatTime(update.updatedAt)} · 新增$count张';
  }
  return '${_formatShortDate(update.updatedAt)} '
      '${_formatTime(update.updatedAt)} · $count张';
}

class _RecentPlanThumbnail extends StatelessWidget {
  const _RecentPlanThumbnail({required this.update});

  final PlanUpdate update;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: 76,
        height: 58,
        child: _PlanImageCard(
          image: update.images.first,
          update: update,
          compact: true,
        ),
      ),
    );
  }
}

class _RecentPlanInfo extends StatelessWidget {
  const _RecentPlanInfo({required this.source, required this.update});

  final PlanSource source;
  final PlanUpdate update;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            source.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: Color(0xff17191c),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _recentUpdateLabel(update),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              color: Color(0xff737a80),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanStatusLabel extends StatelessWidget {
  const _PlanStatusLabel({
    required this.updatedAt,
    this.updatedToday,
  });

  final DateTime updatedAt;
  final bool? updatedToday;

  @override
  Widget build(BuildContext context) {
    final isUpdatedToday = updatedToday ?? _isToday(updatedAt);
    return Text(
      isUpdatedToday ? '今日已更新' : _pastUpdateStatus(updatedAt),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        color:
            isUpdatedToday ? const Color(0xff079669) : const Color(0xff8a9096),
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _TodayUpdateCard extends StatelessWidget {
  const _TodayUpdateCard({
    required this.source,
    required this.update,
    required this.onTap,
  });

  final PlanSource source;
  final PlanUpdate update;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Ink(
        height: 80,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffe7e9eb)),
        ),
        child: Row(
          children: [
            _RecentPlanThumbnail(update: update),
            const SizedBox(width: 12),
            _RecentPlanInfo(source: source, update: update),
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Color(0xffa5abb0),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanSourceRow extends StatelessWidget {
  const _PlanSourceRow({
    required this.source,
    required this.onTap,
    this.historical = false,
  });

  final PlanSource source;
  final VoidCallback onTap;
  final bool historical;

  @override
  Widget build(BuildContext context) {
    final latest = source.latestUpdate;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xffe8eaec)),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 72,
                height: 52,
                child: _PlanImageCard(
                  image: latest.images.first,
                  update: latest,
                  compact: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (historical)
                        const Text(
                          '历史计划',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xff8a9096),
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      else
                        _PlanStatusLabel(
                          updatedAt: latest.updatedAt,
                          updatedToday: source.updatedToday,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_lastUpdatedLabel(latest.updatedAt)} · '
                    '${latest.displayImageCount} 张图片',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff7d848a),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: Color(0xffb0b5ba),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanIdentityCard extends StatelessWidget {
  const _PlanIdentityCard({required this.source});

  final PlanSource source;

  @override
  Widget build(BuildContext context) {
    final latest = source.latestUpdate;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xffe7e9eb)),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: source.brandColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              source.name.characters.first,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: source.brandColor,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Color(0xff151719),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '由 ${source.uploaderName} 上传 · 计划图片资料库',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xff737a80),
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    _PlanStatusLabel(
                      updatedAt: latest.updatedAt,
                      updatedToday: source.updatedToday,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _lastUpdatedLabel(latest.updatedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff858b91),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanUpdateBlock extends StatelessWidget {
  const _PlanUpdateBlock({
    required this.source,
    required this.update,
    required this.onImageTap,
  });

  final PlanSource source;
  final PlanUpdate update;
  final ValueChanged<int> onImageTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xffe7e9eb)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  update.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '${update.displayImageCount} 张',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xff737a80),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _formatDateTime(update.updatedAt),
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xff899097),
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: math.min(update.images.length, 4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.78,
            ),
            itemBuilder: (context, index) {
              final image = update.images[index];
              return InkWell(
                onTap: () => onImageTap(index),
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _PlanImageCard(
                        image: image,
                        update: update,
                      ),
                    ),
                    if (index == 3 && update.images.length > 4)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '+${update.images.length - 4}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PlanImageCard extends StatelessWidget {
  const _PlanImageCard({
    required this.image,
    required this.update,
    this.compact = false,
    this.large = false,
  });

  final PlanImage image;
  final PlanUpdate update;
  final bool compact;
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (image.isRemote) {
      final remoteUrl =
          large ? image.imageUrl! : (image.thumbnailUrl ?? image.imageUrl!);
      return ColoredBox(
        color: Colors.white,
        child: _RetryingNetworkImage(
          url: remoteUrl,
          fit: BoxFit.contain,
          filterQuality: large ? FilterQuality.high : FilterQuality.medium,
        ),
      );
    }
    final titleSize = large ? 22.0 : (compact ? 8.0 : 13.0);
    final cellSize = large ? 16.0 : (compact ? 5.5 : 9.5);
    final headerHeight = large ? 72.0 : (compact ? 22.0 : 42.0);
    return AspectRatio(
      aspectRatio: 0.62,
      child: Container(
        decoration: BoxDecoration(
          color: image.backgroundColor,
          border: Border.all(color: image.lineColor, width: large ? 1.2 : 0.7),
        ),
        child: Column(
          children: [
            Container(
              height: headerHeight,
              width: double.infinity,
              alignment: Alignment.center,
              color: image.headerColor,
              child: Text(
                image.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: image.titleColor,
                  fontSize: titleSize,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(large ? 10 : (compact ? 2 : 5)),
                child: Column(
                  children: [
                    _PlanTableRow(
                      values: const ['日期', '计划内容', '参考', '结果'],
                      textColor: image.strongTextColor,
                      lineColor: image.lineColor,
                      fontSize: cellSize,
                      header: true,
                    ),
                    for (final row in image.rows)
                      _PlanTableRow(
                        values: row,
                        textColor: image.textColor,
                        lineColor: image.lineColor,
                        fontSize: cellSize,
                      ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
            if (!compact)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  large ? 10 : 6,
                  0,
                  large ? 10 : 6,
                  large ? 10 : 6,
                ),
                child: Text(
                  '${_formatShortDate(update.updatedAt)} 更新 · 内容仅作资料展示',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: image.textColor.withValues(alpha: 0.72),
                    fontSize: large ? 12 : 8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RetryingNetworkImage extends StatefulWidget {
  const _RetryingNetworkImage({
    required this.url,
    required this.fit,
    required this.filterQuality,
  });

  final String url;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  State<_RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

class _RetryingNetworkImageState extends State<_RetryingNetworkImage> {
  int _attempt = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(covariant _RetryingNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _attempt = 0;
      _retryScheduled = false;
    }
  }

  String get _url {
    if (_attempt == 0) return widget.url;
    final uri = Uri.parse(widget.url);
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      '_image_retry': '$_attempt',
    }).toString();
  }

  void _scheduleRetry() {
    if (_retryScheduled || _attempt >= 2) return;
    _retryScheduled = true;
    Future<void>.delayed(Duration(milliseconds: 500 * (_attempt + 1)), () {
      if (!mounted) return;
      setState(() {
        _attempt += 1;
        _retryScheduled = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) => Image.network(
        _url,
        key: ValueKey(_url),
        fit: widget.fit,
        filterQuality: widget.filterQuality,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
        errorBuilder: (_, __, ___) {
          _scheduleRetry();
          if (_attempt < 2) {
            return const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Color(0xffa0a6aa),
            ),
          );
        },
      );
}

class _PlanTableRow extends StatelessWidget {
  const _PlanTableRow({
    required this.values,
    required this.textColor,
    required this.lineColor,
    required this.fontSize,
    this.header = false,
  });

  final List<String> values;
  final Color textColor;
  final Color lineColor;
  final double fontSize;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        children: [
          for (var index = 0; index < values.length; index++)
            Expanded(
              flex: index == 1 ? 3 : 2,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: lineColor, width: 0.5),
                    bottom: BorderSide(color: lineColor, width: 0.5),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Text(
                  values[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: fontSize,
                    height: 1,
                    fontWeight: header ? FontWeight.w900 : FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DateGroupHeader extends StatelessWidget {
  const _DateGroupHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final value = DateTime(date.year, date.month, date.day);
    final dayDifference = today.difference(value).inDays;
    final label = switch (dayDifference) {
      0 => '今天',
      1 => '昨天',
      _ => _formatShortDate(date),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 0, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 9,
            height: 9,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xff079669),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: Color(0xff24272a),
            ),
          ),
          if (dayDifference == 0 || dayDifference == 1) ...[
            const SizedBox(width: 7),
            Text(
              _formatShortDate(date),
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xff8a9096),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionText,
    this.onAction,
  });

  final String title;
  final String actionText;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: Color(0xff151719),
              ),
            ),
          ),
          if (actionText.isNotEmpty)
            onAction == null
                ? Text(
                    actionText,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff8a9096),
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    child: Text(actionText),
                  ),
        ],
      ),
    );
  }
}

class _PlanDataSourceNotice extends StatelessWidget {
  const _PlanDataSourceNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    const backgroundColor = Color(0xfffff7e0);
    const borderColor = Color(0xfff0d99a);
    const foregroundColor = Color(0xff9a6b00);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: foregroundColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: foregroundColor,
                fontSize: 12,
                height: 1.25,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanEmptyState extends StatelessWidget {
  const _PlanEmptyState({
    required this.hasError,
    required this.onRetry,
    this.noContentText = '今天暂时没有新计划',
  });

  final bool hasError;
  final VoidCallback onRetry;
  final String noContentText;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasError ? Icons.cloud_off_outlined : Icons.image_outlined,
              size: 38,
              color: const Color(0xffa1a7ab),
            ),
            const SizedBox(height: 10),
            Text(
              hasError ? '计划暂时无法加载' : noContentText,
              style: const TextStyle(color: Color(0xff858b91)),
            ),
            if (hasError) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新加载'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanUpdateEntry {
  const _PlanUpdateEntry(this.source, this.update);

  final PlanSource source;
  final PlanUpdate update;
}

List<PlanSource> _planSourcesFromBody(Map<String, dynamic> body) {
  final items = body['items'] as List<dynamic>? ?? const [];
  return items
      .whereType<Map<String, dynamic>>()
      .map(PlanSource.fromSummaryJson)
      .where(
        (source) =>
            source.id.isNotEmpty &&
            source.activeUpdates.isNotEmpty &&
            source.latestUpdate.images.isNotEmpty,
      )
      .toList(growable: false);
}

class PlanSource {
  const PlanSource({
    required this.id,
    required this.name,
    required this.uploaderName,
    required this.brandColor,
    required this.updates,
    this.isActive = true,
    this.isRemote = false,
    this.updatedToday,
    this.aliasIds = const <String>{},
  });

  factory PlanSource.fromSummaryJson(Map<String, dynamic> json) {
    final updatedAt = _parsePlanDate(json['latestUpdatedAt']);
    final thumbnailUrl = ((json['latestThumbnailUrl'] as String?) ?? '').trim();
    return PlanSource(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名计划'}',
      uploaderName: '${json['uploaderName'] ?? '球镜助手'}',
      brandColor: const Color(0xff079669),
      isRemote: true,
      updatedToday: json['updatedToday'] as bool?,
      aliasIds: (json['aliasIds'] as List<dynamic>? ?? const [])
          .where((value) => value != null)
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toSet(),
      updates: thumbnailUrl.isEmpty
          ? const []
          : [
              PlanUpdate(
                id: 'latest-${json['id'] ?? ''}',
                title: '最新更新',
                updatedAt: updatedAt,
                imageCount: (json['latestImageCount'] as num?)?.toInt(),
                images: [
                  PlanImage.remote(
                    title: '${json['name'] ?? '计划图片'}',
                    imageUrl: thumbnailUrl,
                    thumbnailUrl: thumbnailUrl,
                  ),
                ],
              ),
            ],
    );
  }

  final String id;
  final String name;
  final String uploaderName;
  final Color brandColor;
  final List<PlanUpdate> updates;
  final bool isActive;
  final bool isRemote;
  final bool? updatedToday;
  final Set<String> aliasIds;

  List<PlanUpdate> get activeUpdates =>
      updates.where((update) => update.isActive).toList(growable: false)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  PlanUpdate get latestUpdate => activeUpdates.first;
}

class PlanUpdate {
  const PlanUpdate({
    this.id = '',
    required this.title,
    required this.updatedAt,
    required this.images,
    this.isActive = true,
    this.imageCount,
  });

  factory PlanUpdate.fromJson(Map<String, dynamic> json) {
    final items = json['images'] as List<dynamic>? ?? const [];
    return PlanUpdate(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? '计划更新'}',
      updatedAt: _parsePlanDate(json['publishedAt']),
      images: items
          .whereType<Map<String, dynamic>>()
          .map(PlanImage.fromJson)
          .where((image) => image.imageUrl?.trim().isNotEmpty == true)
          .toList(growable: false),
    );
  }

  final String id;
  final String title;
  final DateTime updatedAt;
  final List<PlanImage> images;
  final bool isActive;
  final int? imageCount;

  int get displayImageCount => imageCount ?? images.length;
}

class PlanImage {
  const PlanImage({
    required this.title,
    required this.headerColor,
    required this.backgroundColor,
    required this.lineColor,
    required this.titleColor,
    required this.textColor,
    required this.strongTextColor,
    required this.rows,
    this.imageUrl,
    this.thumbnailUrl,
    this.width,
    this.height,
  });

  factory PlanImage.fromJson(Map<String, dynamic> json) {
    return PlanImage.remote(
      title: '计划图片',
      imageUrl: '${json['imageUrl'] ?? ''}',
      thumbnailUrl: '${json['thumbnailUrl'] ?? json['imageUrl'] ?? ''}',
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }

  factory PlanImage.remote({
    required String title,
    required String imageUrl,
    required String thumbnailUrl,
    int? width,
    int? height,
  }) {
    return PlanImage(
      title: title,
      headerColor: const Color(0xff079669),
      backgroundColor: Colors.white,
      lineColor: const Color(0xffdfe5e2),
      titleColor: Colors.white,
      textColor: const Color(0xff333333),
      strongTextColor: const Color(0xff111111),
      rows: const [],
      imageUrl: imageUrl,
      thumbnailUrl: thumbnailUrl,
      width: width,
      height: height,
    );
  }

  final String title;
  final Color headerColor;
  final Color backgroundColor;
  final Color lineColor;
  final Color titleColor;
  final Color textColor;
  final Color strongTextColor;
  final List<List<String>> rows;
  final String? imageUrl;
  final String? thumbnailUrl;
  final int? width;
  final int? height;

  bool get isRemote => imageUrl != null;
}

String _planRemoteStatusMessage(Object error) {
  if (error is ApiException) return error.message;
  return '网络连接异常，请稍后重试';
}

DateTime _parsePlanDate(Object? value) {
  return DateTime.tryParse('$value')?.toLocal() ?? DateTime.now();
}

String _formatTime(DateTime value) {
  return '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

String _formatShortDate(DateTime value) {
  return '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

String _formatDateTime(DateTime value) {
  return '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} ${_formatTime(value)}';
}

bool _isSameDay(DateTime first, DateTime second) {
  return first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;
}

bool _isToday(DateTime value) => _isSameDay(value, DateTime.now());

String _pastUpdateStatus(DateTime value) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(value.year, value.month, value.day);
  final difference = today.difference(date).inDays;
  if (difference == 1) return '昨日已更新';
  return '${_formatShortDate(value)} 已更新';
}

String _lastUpdatedLabel(DateTime value) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(value.year, value.month, value.day);
  final difference = today.difference(date).inDays;
  if (difference == 0) return '${_formatTime(value)} 更新';
  if (difference == 1) return '上次：昨天 ${_formatTime(value)}';
  return '上次：${_formatDateTime(value)}';
}
