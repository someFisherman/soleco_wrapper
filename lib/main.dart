import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soleco',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const WebShell(url: 'https://soleco-optimizer.ch/'),
    );
  }
}

class WebShell extends StatefulWidget {
  const WebShell({super.key, required this.url});
  final String url;
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  late final WebViewController _c;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
        onNavigationRequest: (req) {
          final u = req.url;
          if (u.startsWith('tel:') || u.startsWith('mailto:')) {
            launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _reload() => _c.reload();

  Future<bool> _onWillPop() async {
    if (await _c.canGoBack()) { await _c.goBack(); return false; }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(title: const Text('Soleco'), actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ]),
        body: Stack(children: [
          RefreshIndicator(onRefresh: _reload, child: WebViewWidget(controller: _c)),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ]),
      ),
    );
  }
}
