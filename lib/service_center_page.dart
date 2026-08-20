import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const _green = Color(0xff07885d);
const _ink = Color(0xff161a1c);
const _muted = Color(0xff7d8387);
const _line = Color(0xffe8ebea);
const _supportEmail = '1141313485@qq.com';

class ServiceCenterPage extends StatelessWidget {
  const ServiceCenterPage({super.key});

  Future<void> _sendMail(
    BuildContext context, {
    required String subject,
    required String body,
  }) async {
    final uri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      queryParameters: {'subject': subject, 'body': body},
    );
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    if (!context.mounted) return;
    await Clipboard.setData(const ClipboardData(text: _supportEmail));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('邮箱地址已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务中心')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '需要帮助？',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '获取使用帮助，反馈数据问题或提交内容下架申请。',
                  style: TextStyle(color: _muted, fontSize: 14, height: 1.5),
                ),
              ],
            ),
          ),
          _ServiceTile(
            icon: Icons.support_agent_outlined,
            title: '在线客服',
            subtitle: '反馈问题或咨询 App 使用方法',
            action: '联系客服',
            onTap: () => _sendMail(
              context,
              subject: '球镜使用咨询',
              body: '请描述你遇到的问题：\n\n',
            ),
          ),
          _ServiceTile(
            icon: Icons.report_outlined,
            title: '内容投诉与下架',
            subtitle: '反馈版权、内容错误或申请停止展示',
            action: '提交申请',
            onTap: () => _sendMail(
              context,
              subject: '球镜内容投诉或下架申请',
              body: '涉及的计划名称或页面：\n'
                  '问题说明：\n'
                  '相关权利证明（如适用）：\n\n',
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Text(
              '服务中心仅处理软件使用、数据反馈和内容权利请求，不提供购彩、代购、出票、收款或其他资金服务。',
              style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 78),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _green.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _green, size: 22),
              ),
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
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                action,
                style: const TextStyle(
                  color: _green,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right_rounded, color: _muted),
            ],
          ),
        ),
      ),
    );
  }
}
