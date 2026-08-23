import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_data_store.dart';
import 'service_center_page.dart';

const _green = Color(0xff07885d);
const _ink = Color(0xff161a1c);
const _muted = Color(0xff7d8387);
const _line = Color(0xffe8ebea);

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.refreshVersion = 0, super.key});

  final int refreshVersion;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _dataStore = LocalDataStore();
  static final _privacyUri = Uri.parse(
    'https://api.cclloo.com/privacy',
  );
  static final _versionUri = Uri.parse(
    'https://cclloo.com/app/version.json',
  );
  LocalDataSummary _data = const LocalDataSummary.empty();
  bool _loadingData = true;
  bool _checkingUpdate = false;
  String _versionLabel = '正在读取';

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadVersion();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshVersion != oldWidget.refreshVersion) _loadData();
  }

  Future<void> _loadData() async {
    final data = await _dataStore.loadSummary();
    if (!mounted) return;
    setState(() {
      _data = data;
      _loadingData = false;
    });
  }

  Future<void> _loadVersion() async {
    String? label;
    try {
      final package = await PackageInfo.fromPlatform();
      label = '${package.version}（构建 ${package.buildNumber}）';
    } catch (_) {
      if (kIsWeb) {
        try {
          final response = await http.get(Uri.base.resolve('version.json'));
          final decoded = jsonDecode(response.body);
          if (response.statusCode == 200 && decoded is Map) {
            final version = '${decoded['version'] ?? ''}'.trim();
            final build = '${decoded['build_number'] ?? ''}'.trim();
            if (version.isNotEmpty && build.isNotEmpty) {
              label = '$version（构建 $build）';
            }
          }
        } catch (_) {
          // Keep the friendly fallback below when build metadata is unavailable.
        }
      }
    }
    if (!mounted) return;
    setState(() => _versionLabel = label ?? '暂时无法读取');
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final package = await PackageInfo.fromPlatform();
      final response = await http.get(
        kIsWeb ? Uri.base.resolve('version.json') : _versionUri,
      );
      final decoded = jsonDecode(response.body);
      if (response.statusCode != 200 || decoded is! Map) {
        throw const FormatException('版本服务暂时不可用');
      }
      final remoteVersion = '${decoded['version'] ?? ''}'.trim();
      final remoteBuild = int.tryParse('${decoded['build_number'] ?? ''}') ?? 0;
      final currentBuild = int.tryParse(package.buildNumber) ?? 0;
      final hasUpdate = _compareVersions(remoteVersion, package.version) > 0 ||
          (remoteVersion == package.version && remoteBuild > currentBuild);
      if (!mounted) return;
      if (!hasUpdate) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前已是最新版本')),
        );
        return;
      }
      final downloadUrl = '${decoded['download_url'] ?? ''}'.trim();
      final notes = '${decoded['release_notes'] ?? ''}'.trim();
      final shouldOpen = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('发现新版本 $remoteVersion'),
          content: Text(
            notes.isEmpty ? '有新的 App 版本可以使用。' : notes,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: downloadUrl.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('去更新'),
            ),
          ],
        ),
      );
      if (mounted && shouldOpen == true && downloadUrl.isNotEmpty) {
        await _open(context, Uri.tryParse(downloadUrl) ?? _versionUri);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂时无法检查更新，请稍后重试')),
      );
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  static int _compareVersions(String a, String b) {
    final left = a.split('.').map((item) => int.tryParse(item) ?? 0).toList();
    final right = b.split('.').map((item) => int.tryParse(item) ?? 0).toList();
    for (var index = 0; index < 3; index++) {
      final comparison = (left.length > index ? left[index] : 0)
          .compareTo(right.length > index ? right[index] : 0);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  Future<void> _confirmClear({
    required LocalDataKind kind,
    required String title,
    required String message,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清空$title？'),
        content: Text('$message\n\n删除后无法恢复，不会影响原网站内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dataStore.clear(kind);
    await _loadData();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title已清空')),
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接，请稍后重试')),
    );
  }

  void _showDataNotice(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '数据说明',
                style: TextStyle(
                  color: _ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 14),
              Text(
                '比赛、赔率与赛果来自已接入的数据服务。直播比分可能受上游数据更新时间影响，请以官方赛果为准。',
                style: TextStyle(color: _muted, fontSize: 14, height: 1.55),
              ),
              SizedBox(height: 10),
              Text(
                '方案保存于本机，仅用于展示与计算；本应用不售票、不代购、不提供投注或资金服务。',
                style: TextStyle(color: _muted, fontSize: 14, height: 1.55),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Text(
            '设置',
            style: TextStyle(
              color: _ink,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const _SectionLabel('我的数据'),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xffeaf7f2),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                '以下内容只保存在本机。卸载 App、清除浏览器数据或更换设备后可能丢失。清理图片缓存不会删除这些内容。',
                style: TextStyle(color: _green, fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ),
        _LocalDataTile(
          icon: Icons.collections_bookmark_outlined,
          title: '内容收藏',
          subtitle: '已保存当时版本，不受原文后续调整影响',
          count: _data.contentFavorites,
          loading: _loadingData,
          onClear: _data.contentFavorites == 0
              ? null
              : () => _confirmClear(
                    kind: LocalDataKind.contentFavorites,
                    title: '内容收藏',
                    message: '将删除本机保存的 ${_data.contentFavorites} 个内容收藏。',
                  ),
        ),
        _LocalDataTile(
          icon: Icons.notifications_none_rounded,
          title: '关注更新',
          subtitle: '用于在应用内查看原文是否有新版',
          count: _data.followedPlans,
          loading: _loadingData,
          onClear: _data.followedPlans == 0
              ? null
              : () => _confirmClear(
                    kind: LocalDataKind.followedPlans,
                    title: '关注更新',
                    message: '将取消本机记录的 ${_data.followedPlans} 个关注。',
                  ),
        ),
        _LocalDataTile(
          icon: Icons.inventory_2_outlined,
          title: '保存方案',
          subtitle: '仅保留最近7天，最多200个',
          count: _data.savedSchemes,
          loading: _loadingData,
          onClear: _data.savedSchemes == 0
              ? null
              : () => _confirmClear(
                    kind: LocalDataKind.savedSchemes,
                    title: '保存方案',
                    message: '将删除最近7天保存的 ${_data.savedSchemes} 个方案。',
                  ),
        ),
        const _SectionLabel('数据与使用说明'),
        _SettingTile(
          icon: Icons.query_stats_outlined,
          title: '数据说明',
          subtitle: '数据来源、更新状态与本机保存',
          onTap: () => _showDataNotice(context),
        ),
        _SettingTile(
          icon: Icons.privacy_tip_outlined,
          title: '隐私政策',
          subtitle: '数据收集、使用与删除说明',
          onTap: () => _open(context, _privacyUri),
        ),
        const _SectionLabel('支持与关于'),
        _SettingTile(
          icon: Icons.support_agent_outlined,
          title: '服务中心',
          subtitle: '使用帮助、数据反馈与内容下架申请',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ServiceCenterPage(),
            ),
          ),
        ),
        _SettingTile(
          icon: Icons.info_outline,
          title: '版本',
          subtitle: _versionLabel,
        ),
        _SettingTile(
          icon: Icons.system_update_outlined,
          title: '检查 App 更新',
          subtitle: _checkingUpdate ? '正在检查，请稍候' : '检查是否有新的安装包',
          onTap: _checkingUpdate ? null : _checkForUpdate,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Text(
            '理性使用：本工具仅提供赛事数据与计算参考，不构成赛事结果承诺或投注建议。未成年人请勿参与彩票活动。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.55),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          label,
          style: const TextStyle(
            color: _muted,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _LocalDataTile extends StatelessWidget {
  const _LocalDataTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.loading,
    required this.onClear,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int count;
  final bool loading;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        child: Container(
          constraints: const BoxConstraints(minHeight: 74),
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: Row(
            children: [
              Icon(icon, color: _green, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                loading ? '—' : '$count 个',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                onPressed: onClear,
                tooltip: onClear == null ? '暂无可清空内容' : '清空$title',
                icon: const Icon(Icons.delete_outline_rounded),
                color: onClear == null ? _line : Colors.redAccent,
              ),
            ],
          ),
        ),
      );
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _line)),
            ),
            child: Row(
              children: [
                Icon(icon, color: _green, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (onTap != null)
                  const Icon(Icons.chevron_right_rounded, color: _muted),
              ],
            ),
          ),
        ),
      );
}
