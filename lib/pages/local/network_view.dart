import 'package:PiliPlus/pages/local_player/controller.dart';
import 'package:PiliPlus/services/local_media/local_network_service.dart';
import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

/// 网络（局域网）Tab：SMB 自动发现 + 书签 + 逐层浏览。
/// 主机作为一级目录、共享作为子目录（对齐 VLC / Windows 资源管理器），
/// 不采用「弹框挑共享」式流程。
class LocalNetworkView extends StatefulWidget {
  const LocalNetworkView({super.key});

  @override
  State<LocalNetworkView> createState() => _LocalNetworkViewState();
}

class _LocalNetworkViewState extends State<LocalNetworkView>
    with AutomaticKeepAliveClientMixin {
  final LocalNetworkService _service = Get.put(LocalNetworkService());

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (_service.discovered.isEmpty && !_service.discovering.value) {
      _service.startDiscovery();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      children: [
        _sectionHeader(
          context,
          '发现的网络位置（SMB）',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => _service.discovering.value
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: '重新发现',
                        onPressed: _service.startDiscovery,
                      ),
              ),
            ],
          ),
        ),
        Obx(() {
          if (_service.discovered.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '未发现共享。请确认与 NAS/电脑处于同一局域网，'
                '或在下方手动添加来源（smb/ftp/nfs/webdav/http）。',
                style: TextStyle(fontSize: 12),
              ),
            );
          }
          return Column(
            children: _service.discovered
                .map(
                  (item) => ListTile(
                    leading: Icon(
                      item.isDir ? Icons.dns_outlined : Icons.movie_outlined,
                    ),
                    title: Text(item.name),
                    subtitle: Text(
                      LocalNetworkService.redactUrl(item.uri),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _openBrowse(item.uri, item.name),
                    onLongPress: () => _showItemMenu(item),
                  ),
                )
                .toList(),
          );
        }),
        const Divider(),
        _sectionHeader(
          context,
          '书签',
          trailing: IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加网络来源',
            onPressed: () => _showBookmarkDialog(context, _service),
          ),
        ),
        Obx(() {
          if (_service.bookmarks.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '暂无书签。点右上角 + 手动添加 smb/ftp/nfs/webdav/http(s) 来源。',
                style: TextStyle(fontSize: 12),
              ),
            );
          }
          return Column(
            children: List.generate(_service.bookmarks.length, (i) {
              final b = _service.bookmarks[i];
              return ListTile(
                leading: const Icon(Icons.bookmark_border),
                title: Text(b.name),
                // 界面展示一律脱敏，不显示密码
                subtitle: Text(
                  b.redactedUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _openBrowse(b.url, b.name),
                onLongPress: () => _showBookmarkMenu(b, i),
              );
            }),
          );
        }),
        Obx(() {
          if (_service.downloadProgress.isEmpty) {
            return const SizedBox.shrink();
          }
          return Column(
            children: [
              const Divider(),
              _sectionHeader(context, '下载中'),
              ..._service.downloadProgress.entries.map(
                (e) => ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text('任务 #${e.key}'),
                  subtitle: LinearProgressIndicator(value: e.value),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => _service.cancelDownload(e.key),
                  ),
                ),
              ),
            ],
          );
        }),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  void _openBrowse(String url, String title) {
    Get.to(() => NetBrowsePage(url: url, title: title));
  }

  void _showItemMenu(NetItem item) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: const Text('收藏为书签'),
              onTap: () {
                Navigator.pop(context);
                _service.addBookmark(NetBookmark(name: item.name, url: item.uri));
                SmartDialog.showToast('已加入书签');
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制地址（脱敏）'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(
                  ClipboardData(text: LocalNetworkService.redactUrl(item.uri)),
                );
                SmartDialog.showToast('已复制（密码已脱敏）');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBookmarkMenu(NetBookmark b, int index) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(context);
                _showBookmarkDialog(context, _service, index: index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制地址（脱敏）'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: b.redactedUrl));
                SmartDialog.showToast('已复制（密码已脱敏）');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除书签'),
              onTap: () {
                Navigator.pop(context);
                _service.removeBookmark(index);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 逐层浏览页（smb/ftp/nfs/webdav/http）。目录入栈、文件即播；
/// 同目录其他视频自动成为播放列表。
class NetBrowsePage extends StatefulWidget {
  final String url;
  final String title;

  const NetBrowsePage({super.key, required this.url, required this.title});

  @override
  State<NetBrowsePage> createState() => _NetBrowsePageState();
}

class _NetBrowsePageState extends State<NetBrowsePage> {
  final LocalNetworkService _service = Get.find<LocalNetworkService>();

  final List<(String url, String title)> _stack = [];
  late String _currentUrl = widget.url;
  late String _currentTitle = widget.title;

  @override
  void initState() {
    super.initState();
    _service.browse(widget.url);
  }

  Future<void> _push(String url, String title) async {
    setState(() {
      _stack.add((_currentUrl, _currentTitle));
      _currentUrl = url;
      _currentTitle = title;
    });
    await _service.browse(url);
  }

  Future<bool> _pop() async {
    if (_stack.isEmpty) return false;
    final last = _stack.removeLast();
    setState(() {
      _currentUrl = last.$1;
      _currentTitle = last.$2;
    });
    await _service.browse(_currentUrl);
    return true;
  }

  void _play(List<NetItem> files, int index) {
    final controller = LocalPlayerController(
      uris: files.map((e) => e.uri).toList(),
      titles: files.map((e) => e.name).toList(),
      initialIndex: index,
      isNetwork: true,
      playlistName: _currentTitle,
    );
    Get.toNamed('/localPlayer', arguments: controller);
  }

  Future<void> _download(NetItem item) async {
    final dir = await getTemporaryDirectory();
    final id = await _service.download(item.uri, dir.path, item.name);
    if (id > 0 && mounted) {
      SmartDialog.showToast('开始下载：${item.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (!await _pop()) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_currentTitle),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () => _service.browse(_currentUrl),
            ),
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              tooltip: '收藏当前目录',
              onPressed: () {
                _service.addBookmark(
                  NetBookmark(name: _currentTitle, url: _currentUrl),
                );
                SmartDialog.showToast('已加入书签（凭据仅保存在本机）');
              },
            ),
          ],
        ),
        body: Obx(() {
          if (_service.browsing.value && _service.browseItems.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_service.browseItems.isEmpty) {
            return const Center(child: Text('（空目录，或需要凭据/无法访问）'));
          }
          final items = _service.browseItems.toList();
          final files = items.where((e) => !e.isDir).toList();
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item.isDir) {
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(item.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(item.uri, item.name),
                  onLongPress: () => _fileMenu(item, null, 0),
                );
              }
              final fileIndex = files.indexOf(item);
              return ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: Text(item.name),
                subtitle: item.durationMs > 0
                    ? Text(DurationUtils.formatDuration(item.durationMs ~/ 1000))
                    : null,
                onTap: () => _play(files, fileIndex < 0 ? 0 : fileIndex),
                onLongPress: () => _fileMenu(item, files, fileIndex),
              );
            },
          );
        }),
      ),
    );
  }

  void _fileMenu(NetItem item, List<NetItem>? files, int index) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!item.isDir)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载到本地'),
                onTap: () {
                  Navigator.pop(context);
                  _download(item);
                },
              ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制地址（脱敏）'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(
                  ClipboardData(text: LocalNetworkService.redactUrl(item.uri)),
                );
                SmartDialog.showToast('已复制（密码已脱敏）');
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 添加/编辑网络来源书签（主机一级、共享子级，凭据写入 URL 并只存本机）。
Future<void> _showBookmarkDialog(
  BuildContext context,
  LocalNetworkService service, {
  int? index,
}) async {
  final existing = index != null ? service.bookmarks[index] : null;
  final nameController = TextEditingController(text: existing?.name ?? '');
  final hostController = TextEditingController();
  final pathController = TextEditingController();
  final userController = TextEditingController();
  final passController = TextEditingController();
  String scheme = 'smb';

  if (existing != null) {
    final uri = Uri.tryParse(existing.url);
    if (uri != null) {
      scheme = uri.scheme;
      hostController.text = uri.hasAuthority
          ? '${uri.host}${uri.hasPort && uri.port != 0 ? ':${uri.port}' : ''}'
          : uri.host;
      pathController.text = uri.path;
      userController.text = uri.userInfo.contains(':')
          ? uri.userInfo.split(':').first
          : uri.userInfo;
      // 出于安全考虑不回显已保存的密码
    }
  }

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? '添加网络来源' : '编辑书签'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: scheme,
                decoration: const InputDecoration(labelText: '协议'),
                items: const [
                  DropdownMenuItem(value: 'smb', child: Text('SMB')),
                  DropdownMenuItem(value: 'ftp', child: Text('FTP')),
                  DropdownMenuItem(value: 'nfs', child: Text('NFS')),
                  DropdownMenuItem(value: 'webdav', child: Text('WebDAV (http)')),
                  DropdownMenuItem(value: 'webdavs', child: Text('WebDAV (https)')),
                  DropdownMenuItem(value: 'http', child: Text('HTTP')),
                  DropdownMenuItem(value: 'https', child: Text('HTTPS')),
                ],
                onChanged: (v) => setState(() => scheme = v ?? 'smb'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: hostController,
                decoration: const InputDecoration(
                  labelText: '主机',
                  hintText: '192.168.1.10 或 nas.local[:端口]',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: pathController,
                decoration: const InputDecoration(
                  labelText: '路径（可选）',
                  hintText: '/share/movies',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: userController,
                decoration: const InputDecoration(labelText: '用户名（可选）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: passController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: existing == null ? '密码（可选）' : '密码（留空保持不变）',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final host = hostController.text.trim();
              if (host.isEmpty) {
                SmartDialog.showToast('请填写主机地址');
                return;
              }
              final user = userController.text.trim();
              final pass = passController.text;
              final auth = user.isEmpty
                  ? ''
                  : '${Uri.encodeComponent(user)}${pass.isEmpty ? '' : ':${Uri.encodeComponent(pass)}'}@';
              final path = pathController.text.trim();
              final url = '$scheme://$auth$host${path.isEmpty ? '' : (path.startsWith('/') ? path : '/$path')}';
              final name = nameController.text.trim().isEmpty
                  ? host
                  : nameController.text.trim();
              final bookmark = NetBookmark(name: name, url: url);
              if (index != null) {
                service.updateBookmark(index, bookmark);
              } else {
                service.addBookmark(bookmark);
              }
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
