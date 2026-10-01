import 'package:PiliPlus/pages/local/library_view.dart';
import 'package:PiliPlus/pages/local/network_view.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块：媒体库（本机）与 网络（局域网）两个 Tab。
/// 交互组织参照 VLC / OPlayer：来源/目录逐层浏览，点文件即播。
class LocalPage extends StatefulWidget {
  const LocalPage({super.key});

  @override
  State<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends State<LocalPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '媒体库'),
            Tab(text: '网络'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          LocalLibraryView(),
          LocalNetworkView(),
        ],
      ),
    );
  }
}
