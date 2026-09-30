import 'package:PiliPlus/services/smb/srvsvc.dart';
import 'package:material_ui/material_ui.dart';

/// 共享选择对话框的结果: 选中一个共享, 或用户要求手动输入地址
class SmbSharePickResult {
  const SmbSharePickResult.share(this.share) : manual = false;
  const SmbSharePickResult.manual()
    : share = null,
      manual = true;

  final SmbShare? share;
  final bool manual;
}

/// 「选择共享」对话框(参照 VLC 点开局域网主机后的共享列表)。
/// 共享由 SRVSVC 自动枚举得到, 用户不再需要手填共享名;
/// 列表底部保留「手动输入地址」兜底(个别服务端禁用 RPC 时用)。
Future<SmbSharePickResult?> showSmbSharePicker(
  BuildContext context, {
  required String hostLabel,
  required String address,
  required List<SmbShare> shares,
}) {
  return showDialog<SmbSharePickResult>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(hostLabel),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            address,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 8),
        if (shares.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Text('这台主机没有报告可浏览的共享。'),
          ),
        for (final share in shares)
          ListTile(
            leading: const Icon(Icons.folder_shared_outlined),
            title: Text(share.name),
            subtitle: share.remark.isEmpty
                ? null
                : Text(
                    share.remark,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () =>
                Navigator.of(context).pop(SmbSharePickResult.share(share)),
          ),
        const Divider(height: 8),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('手动输入地址…'),
          onTap: () =>
              Navigator.of(context).pop(const SmbSharePickResult.manual()),
        ),
      ],
    ),
  );
}

/// SMB 凭据
typedef SmbCredentials = ({String user, String password, String domain});

/// 「需要账号」对话框: 服务端拒绝匿名枚举共享时弹出
Future<SmbCredentials?> showSmbCredentialsDialog(
  BuildContext context, {
  required String hostLabel,
  String? initialUser,
}) {
  return showDialog<SmbCredentials>(
    context: context,
    builder: (context) => _SmbCredentialsDialog(
      hostLabel: hostLabel,
      initialUser: initialUser,
    ),
  );
}

class _SmbCredentialsDialog extends StatefulWidget {
  const _SmbCredentialsDialog({required this.hostLabel, this.initialUser});

  final String hostLabel;
  final String? initialUser;

  @override
  State<_SmbCredentialsDialog> createState() => _SmbCredentialsDialogState();
}

class _SmbCredentialsDialogState extends State<_SmbCredentialsDialog> {
  late final _userCtr = TextEditingController(text: widget.initialUser ?? '');
  late final _passCtr = TextEditingController();
  late final _domainCtr = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _userCtr.dispose();
    _passCtr.dispose();
    _domainCtr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('连接 ${widget.hostLabel}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '这台主机不允许匿名获取共享列表，请输入账号密码。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userCtr,
              autofocus: true,
              decoration: const InputDecoration(labelText: '用户名'),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: _passCtr,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            TextField(
              controller: _domainCtr,
              decoration: const InputDecoration(
                labelText: '域/工作组(可留空)',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('连接')),
      ],
    );
  }

  void _submit() {
    Navigator.of(
      context,
    ).pop((
      user: _userCtr.text.trim(),
      password: _passCtr.text,
      domain: _domainCtr.text.trim(),
    ));
  }
}
