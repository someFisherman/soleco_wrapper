import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const App());

/// ----------------------------------------------
/// App
/// ----------------------------------------------
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soleco',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const WebShell(),
    );
  }
}

/// ----------------------------------------------
/// WebShell: Lädt die Seite, erkennt Login-Ziel,
/// und zeigt danach deine eigene UI.
/// ----------------------------------------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String startUrl = 'https://soleco-optimizer.ch/VehicleAppointments';
  late final WebViewController _c;

  bool _loading = true;
  bool _showCustomUI = false; // wenn wahr, zeigen wir nur noch den "Sofortladen"-Screen

  @override
  void initState() {
    super.initState();

    // iOS/Android WebView initialisieren
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (url) async {
            setState(() => _loading = false);
            // Wenn wir auf der Zielseite sind (nach Login), wechsel auf Custom-UI
            if (url.contains('VehicleAppointments')) {
              setState(() => _showCustomUI = true);
            }
          },
          onNavigationRequest: (request) {
            final url = request.url;
            // tel:, mailto: usw. im System öffnen
            if (url.startsWith('tel:') || url.startsWith('mailto:')) {
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(startUrl));
  }

  Future<void> _reload() => _c.reload();

  @override
  Widget build(BuildContext context) {
    // Wenn _showCustomUI == true, zeigen wir nur noch unseren Screen
    if (_showCustomUI) {
      return CustomChargingScreen(controller: _c, onBackToWeb: () {
        setState(() => _showCustomUI = false);
      });
    }

    // Sonst: normale WebView mit Progress
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh))],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _c),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

/// ----------------------------------------------
/// CustomChargingScreen: Deine einfache UI
/// - Eingabe "Minuten"
/// - Button "Sofortladen starten"
/// - Button "Zur Webseite" (falls du mal wieder reinsehen willst)
/// ----------------------------------------------
class CustomChargingScreen extends StatefulWidget {
  final WebViewController controller;
  final VoidCallback onBackToWeb;
  const CustomChargingScreen({super.key, required this.controller, required this.onBackToWeb});

  @override
  State<CustomChargingScreen> createState() => _CustomChargingScreenState();
}

class _CustomChargingScreenState extends State<CustomChargingScreen> {
  final TextEditingController _minutesCtrl = TextEditingController(text: '30');
  bool _busy = false;

  Future<void> _startCharging() async {
    final minutes = _minutesCtrl.text.trim();
    if (minutes.isEmpty) return;

    setState(() => _busy = true);

    // Dieses JS setzt "Minutes" und klickt "Parameter aktivieren".
    // Es versucht erst die DevExtreme-Form zu nutzen, ansonsten Fallbacks.
    final js = '''
      (function(){
        try {
          var m = parseInt("$minutes", 10);
          if (isNaN(m) || m < 0) m = 0;

          // 1) DevExtreme-Form (falls vorhanden)
          try {
            if (window.DevExpress && window.jQuery) {
              var form = jQuery("#parameterform").dxForm("instance");
              if (form && form.updateData) {
                form.updateData("Minutes", m);
              }
            }
          } catch(e) { console.log("dxForm update failed", e); }

          // 2) Hidden Input (falls vorhanden)
          var hidden = document.querySelector("input[name='Minutes']");
          if (hidden) { hidden.value = m; }

          // 3) Sichtbares Eingabefeld (Fallback)
          // Versuche ein passendes Input zu finden und 'input' Event zu feuern
          var vis = document.querySelector("input#Minutes, input.dx-texteditor-input");
          if (vis) {
            vis.value = m;
            try {
              vis.dispatchEvent(new Event('input', {bubbles:true}));
              vis.dispatchEvent(new Event('change', {bubbles:true}));
              var ev = document.createEvent('HTMLEvents'); ev.initEvent('keyup', true, false); vis.dispatchEvent(ev);
            } catch(e){}
          }

          // 4) Button klicken
          var btn = document.querySelector("#PostParametersButton, .dx-button");
          if (btn) { btn.click(); }
        } catch(e) { console.log("JS error", e); }
      })();
    ''';

    try {
      await widget.controller.runJavaScript(js);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sofortladung für $minutes Minuten ausgelöst')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fehler beim Auslösen der Sofortladung')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).size.width > 500 ? 24.0 : 16.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco – Schnellstart'),
        actions: [
          TextButton.icon(
            onPressed: widget.onBackToWeb,
            icon: const Icon(Icons.public),
            label: const Text('Zur Webseite'),
          )
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Sofortladung mit voller Leistung',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _minutesCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Minuten',
                hintText: 'z. B. 30',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _busy ? null : _startCharging,
              icon: const Icon(Icons.flash_on),
              label: Text(_busy ? 'Bitte warten…' : 'Sofortladen starten'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
            const SizedBox(height: 12),
            Text(
              'Hinweis: Du musst einmal eingeloggt sein. Danach merkt sich die Seite in der Regel die Session (Cookies). '
              'Wenn dich die App nach einem Schließen wieder ausloggt, sag mir Bescheid – dann bauen wir ein Cookie-Backup ein.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
