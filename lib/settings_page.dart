import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const _green = Color(0xff07885d);
const _ink = Color(0xff161a1c);
const _muted = Color(0xff7d8387);
const _line = Color(0xffe8ebea);

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static final _privacyUri = Uri.parse(
    'https://github.com/qq1141313485-ai/dropll/blob/main/docs/PRIVACY_POLICY.md',
  );
  static final _feedbackUri = Uri.parse(
    'https://github.com/qq1141313485-ai/dropll/issues/new',
  );

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
                '比赛、赔率与赛果来自已接入的数据服务。直播比分可能受上游数据更新影响；显示“比分更新中”时，请以官方赛果为准。',
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
          icon: Icons.feedback_outlined,
          title: '问题反馈',
          subtitle: '提交问题时请勿附带个人敏感信息',
          onTap: () => _open(context, _feedbackUri),
        ),
        const _SettingTile(
          icon: Icons.info_outline,
          title: '版本',
          subtitle: '1.0.0（发布准备中）',
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
