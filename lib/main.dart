import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const SolecoApp());
}

class SolecoApp extends StatelessWidget {
  const SolecoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soleco Optimizer',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Brand.primary,
          secondary: Brand.petrol,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Brand.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        scaffoldBackgroundColor: Brand.surface,
      ),
      home: const WebShell(),
    );
  }
}

// Brand Colors
class Brand {
  static const Color primary = Color(0xFFF28C00); // Kolibri-Orange
  static const Color primaryDark = Color(0xFFCC7600); // Dunkleres Orange
  static const Color petrol = Color(0xFF155D78); // Petrolblau
  static const Color surface = Color(0xFFF7F8FA); // Sehr helles Grau
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  late final WebViewController _main;
  late final WebviewCookieManager cookieMgr;
  late final FlutterSecureStorage storage;
  late final FlutterLocalNotificationsPlugin notifications;
  
  // State variables
  bool _loading = false;
  bool _showStartMenu = false; // Startet versteckt - nur nach Login
  bool _didAutoLogin = false;
  bool _isLoggedIn = false; // Login-Status verfolgen
  Timer? _vehicleMonitor;
  String? _lastVehicleStatus;
  
  // URLs
  final String startVehicleUrl = 'https://soleco-optimizer.ch/VehicleAppointments';
  final String startViewsUrl = 'https://soleco-optimizer.ch/Views';
  
  // Storage keys
  static const String _kUser = 'soleco_user';
  static const String _kPass = 'soleco_pass';
  static const String _kCookieStore = 'soleco_cookies';

  @override
  void initState() {
    super.initState();
    _initMainController();
    _initNotifications();
    
    // Cookies laden und Start-URL öffnen
    Future.microtask(() async {
      await _restoreCookies();
      await _main.loadRequest(Uri.parse(startVehicleUrl));
      // Starte Vehicle Monitoring nach kurzer Verzögerung
      Future.delayed(const Duration(seconds: 5), () {
        _startVehicleMonitoring();
      });
    });
  }

  @override
  void dispose() {
    _vehicleMonitor?.cancel();
    super.dispose();
  }

  void _initMainController() {
    cookieMgr = WebviewCookieManager();
    storage = const FlutterSecureStorage();
    
    _main = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (url) async {
            setState(() => _loading = false);

            // B2C Login Detection
            if (await _isB2CLoginDom()) {
              if (!_didAutoLogin) {
                _didAutoLogin = true;
                await _autoLoginB2C();
              }
              await _persistCookies(url);
              setState(() => _isLoggedIn = false); // Nicht eingeloggt
              return;
            }

            // Vehicle-Appointments / Views -> Eingeloggt
            if (url.contains('/VehicleAppointments') || url.contains('/Views')) {
              await _persistCookies(url);
              setState(() => _isLoggedIn = true); // Eingeloggt
              return;
            }

            await _persistCookies(url);
          },
          onNavigationRequest: (req) {
            final u = req.url;
            if (u.startsWith('tel:') || u.startsWith('mailto:')) {
              launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  Future<void> _initNotifications() async {
    notifications = FlutterLocalNotificationsPlugin();
    
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    
    await notifications.initialize(initSettings);
    
    // Android Notification Channel
    const androidChannel = AndroidNotificationChannel(
      'vehicle_channel',
      'Fahrzeug Benachrichtigungen',
      description: 'Benachrichtigungen für Fahrzeugstatus',
      importance: Importance.high,
    );
    
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'vehicle_channel',
      'Fahrzeug Benachrichtigungen',
      channelDescription: 'Benachrichtigungen für Fahrzeugstatus',
      importance: Importance.high,
      priority: Priority.high,
    );
    
    const iosDetails = DarwinNotificationDetails();
    
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    
    await notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
    );
  }

  // Vehicle Detection System
  Future<String?> _detectVehicleStatus() async {
    try {
      final result = await _main.runJavaScriptReturningResult('''
        (function(){
          // Suche nach spezifischen SVG-Text-Elementen
          var statusEls = [
            document.getElementById('text860'),
            document.getElementById('tspan858'),
            document.getElementById('status')
          ];
          
          for(var i = 0; i < statusEls.length; i++) {
            if(statusEls[i] && statusEls[i].textContent) {
              var text = statusEls[i].textContent.trim();
              if(text) return text;
            }
          }
          
          // Fallback: Suche in allen Text-Elementen
          var allTexts = document.querySelectorAll('text, tspan, span, div');
          var pluggedIn = ['Home, Ready', 'Charging', 'Connected', 'Plugged', 'Ready', 'Available'];
          var notPlugged = ['Away', 'Disconnected', 'Not Connected', 'Offline'];
          
          for(var i = 0; i < allTexts.length; i++) {
            var text = allTexts[i].textContent ? allTexts[i].textContent.trim() : '';
            if(pluggedIn.includes(text) || notPlugged.includes(text)) {
              return text;
            }
          }
          
          return null;
        })();
      ''');
      
      return result.toString() != 'null' ? result.toString() : null;
    } catch (e) {
      print('🚗 Vehicle detection error: $e');
      return null;
    }
  }

  void _startVehicleMonitoring() {
    _vehicleMonitor?.cancel();
    _vehicleMonitor = Timer.periodic(const Duration(seconds: 10), (timer) async {
      try {
        final status = await _detectVehicleStatus();
        if (status != null && status != _lastVehicleStatus) {
          _lastVehicleStatus = status;
          
          // Benachrichtigung bei Statusänderung
          if (status.contains('Charging') || status.contains('Connected')) {
            await _showNotification(
              '🚗 Fahrzeug Status',
              'Ihr Fahrzeug ist jetzt: $status'
            );
          }
        }
      } catch (e) {
        print('🚗 Monitoring error: $e');
      }
    });
  }

  // Cookie Management
  Future<void> _restoreCookies() async {
    try {
      final raw = await storage.read(key: _kCookieStore);
      if (raw == null) return;
      
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final domain = entry.key;
        final list = (entry.value as List).cast<Map>();
        
        for (final m in list) {
          try {
            final c = Cookie(m['name'] as String, m['value'] as String)
              ..domain = domain
              ..path = (m['path'] as String?) ?? '/'
              ..secure = (m['secure'] as bool?) ?? true;
            await cookieMgr.setCookies([c]);
          } catch (_) {}
        }
      }
    } catch (e) {
      print('🍪 Cookie restore error: $e');
    }
  }

  Future<void> _persistCookies(String currentUrl) async {
    try {
      final uri = Uri.parse(currentUrl);
      final cookies = await cookieMgr.getCookies(currentUrl);
      final raw = await storage.read(key: _kCookieStore);
      
      final Map<String, List<Map<String, dynamic>>> store = 
          raw != null ? Map<String, List<Map<String, dynamic>>>.from(
            jsonDecode(raw).map((k, v) => MapEntry(k, List<Map<String, dynamic>>.from(v)))
          ) : {};
      
      for (final c in cookies) {
        final domain = c.domain ?? uri.host;
        store.putIfAbsent(domain, () => []);
        final list = store[domain]!;
        
        final idx = list.indexWhere(
          (m) => m['name'] == c.name && m['path'] == (c.path ?? '/')
        );
        
        final m = {
          'name': c.name,
          'value': c.value,
          'path': c.path ?? '/',
          'secure': c.secure ?? true,
        };
        
        if (idx >= 0) {
          list[idx] = m;
        } else {
          list.add(m);
        }
      }
      
      await storage.write(key: _kCookieStore, value: jsonEncode(store));
    } catch (e) {
      print('🍪 Cookie persist error: $e');
    }
  }

  // B2C Auto-Login
  Future<bool> _isB2CLoginDom() async {
    try {
      final res = await _main.runJavaScriptReturningResult('''
        (function(){
          var f=document.getElementById('localAccountForm');
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var n=document.getElementById('next');
          return !!(f&&u&&p&&n);
        })();
      ''');
      return res.toString() == 'true' || res.toString() == '1';
    } catch (e) {
      return false;
    }
  }

  String _esc(String s) => s.replaceAll("'", "\\'").replaceAll('"', '\\"');

  Future<void> _autoLoginB2C() async {
    try {
      final user = await storage.read(key: _kUser);
      final pass = await storage.read(key: _kPass);
      if (user == null || pass == null) return;
      
      final js = '''
        function setVal(el,val){
          if(!el) return false;
          el.focus(); el.value=val;
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
          var ev=document.createEvent('HTMLEvents'); 
          ev.initEvent('keyup',true,false); 
          el.dispatchEvent(ev);
        }
        function tryLogin(){
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var btn=document.getElementById('next');
          if(u&&p&&btn){
            setVal(u,'${_esc(user)}');
            setVal(p,'${_esc(pass)}');
            btn.click();
            return true;
          }
          return false;
        }
        if(!tryLogin()){
          var tries=0;
          var t=setInterval(function(){ 
            tries++; 
            if(tryLogin()||tries>50){clearInterval(t);} 
          },100);
        }
      ''';
      
      await _main.runJavaScript(js);
    } catch (e) {
      print('🔐 Auto-login error: $e');
    }
  }

  // Vehicle Selection - Verbesserte Suche
  Future<List<Map<String, dynamic>>> _scanVehicles() async {
    try {
      final result = await _main.runJavaScriptReturningResult('''
        (function(){
          var vehicles = [];
          
          // 1. DevExtreme SelectBox suchen
          var selectBoxes = document.querySelectorAll('[data-role="selectbox"]');
          for(var i = 0; i < selectBoxes.length; i++) {
            var sb = selectBoxes[i];
            var dataSource = sb._dxSelectBox && sb._dxSelectBox.option('dataSource');
            if(dataSource) {
              var items = dataSource.items ? dataSource.items() : dataSource._items || [];
              for(var j = 0; j < items.length; j++) {
                var item = items[j];
                vehicles.push({
                  text: item.text || item.name || item.displayValue || JSON.stringify(item),
                  value: item.value || item.id || j,
                  index: j
                });
              }
            }
          }
          
          // 2. Fallback: Suche nach Select-Elementen
          if(vehicles.length === 0) {
            var selects = document.querySelectorAll('select');
            for(var i = 0; i < selects.length; i++) {
              var select = selects[i];
              var options = select.querySelectorAll('option');
              for(var j = 0; j < options.length; j++) {
                var option = options[j];
                if(option.value && option.textContent.trim()) {
                  vehicles.push({
                    text: option.textContent.trim(),
                    value: option.value,
                    index: j
                  });
                }
              }
            }
          }
          
          // 3. Fallback: Suche nach Dropdown-ähnlichen Elementen
          if(vehicles.length === 0) {
            var dropdowns = document.querySelectorAll('[class*="dropdown"], [class*="select"], [class*="vehicle"]');
            for(var i = 0; i < dropdowns.length; i++) {
              var dropdown = dropdowns[i];
              var items = dropdown.querySelectorAll('[data-value], [data-id], option, li');
              for(var j = 0; j < items.length; j++) {
                var item = items[j];
                var text = item.textContent ? item.textContent.trim() : '';
                var value = item.getAttribute('data-value') || item.getAttribute('data-id') || item.value || j;
                if(text && text.length > 0) {
                  vehicles.push({
                    text: text,
                    value: value,
                    index: j
                  });
                }
              }
            }
          }
          
          return vehicles;
        })();
      ''');
      
      if (result.toString() != 'null') {
        final List<dynamic> list = jsonDecode(result.toString());
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      print('🚗 Vehicle scan error: $e');
      return [];
    }
  }

  Future<bool> _selectVehicle(Map<String, dynamic> vehicle) async {
    try {
      final js = '''
        (function(){
          // 1. DevExtreme SelectBox
          var selectBoxes = document.querySelectorAll('[data-role="selectbox"]');
          for(var i = 0; i < selectBoxes.length; i++) {
            var sb = selectBoxes[i];
            if(sb._dxSelectBox) {
              sb._dxSelectBox.option('selectedIndex', ${vehicle['index']});
              sb._dxSelectBox.option('value', '${vehicle['value']}');
              sb._dxSelectBox.option('selectedItem', ${jsonEncode(vehicle)});
              
              // Events triggern
              sb.dispatchEvent(new Event('change', {bubbles: true}));
              sb.dispatchEvent(new Event('dxchange', {bubbles: true}));
              return true;
            }
          }
          
          // 2. Fallback: Normale Select-Elemente
          var selects = document.querySelectorAll('select');
          for(var i = 0; i < selects.length; i++) {
            var select = selects[i];
            select.selectedIndex = ${vehicle['index']};
            select.value = '${vehicle['value']}';
            select.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
          }
          
          return false;
        })();
      ''';
      
      final result = await _main.runJavaScriptReturningResult(js);
      return result.toString() == 'true';
    } catch (e) {
      print('🚗 Vehicle selection error: $e');
      return false;
    }
  }

  // Vehicle Data Loading
  Future<Map<String, double>> _loadVehicleData() async {
    try {
      // Current Range von Views-Seite laden
      await _main.loadRequest(Uri.parse(startViewsUrl));
      await Future.delayed(const Duration(seconds: 2));
      
      final currentRangeResult = await _main.runJavaScriptReturningResult('''
        (function(){
          var texts = document.querySelectorAll('text, tspan, span, div');
          for(var i = 0; i < texts.length; i++) {
            var text = texts[i].textContent;
            if(text) {
              var match = text.match(/(\d+)\s*km/i);
              if(match) {
                var km = parseInt(match[1]);
                if(km >= 50 && km <= 500) {
                  return km;
                }
              }
            }
          }
          return null;
        })();
      ''');
      
      double currentRange = 0;
      if (currentRangeResult.toString() != 'null') {
        currentRange = double.tryParse(currentRangeResult.toString()) ?? 0;
      }
      
      // Max Range von Settings laden
      await _main.loadRequest(Uri.parse('${startViewsUrl.replaceAll('/Views', '/Settings/VehiclesConfig')}'));
      await Future.delayed(const Duration(seconds: 2));
      
      final maxRangeResult = await _main.runJavaScriptReturningResult('''
        (function(){
          var inputs = document.querySelectorAll('input[name*="DistanceMax"], input[id*="DistanceMax"]');
          for(var i = 0; i < inputs.length; i++) {
            var val = inputs[i].value;
            if(val) {
              var km = parseInt(val);
              if(km >= 200 && km <= 1000) {
                return km;
              }
            }
          }
          return null;
        })();
      ''');
      
      double maxRange = 0;
      if (maxRangeResult.toString() != 'null') {
        maxRange = double.tryParse(maxRangeResult.toString()) ?? 0;
      }
      
      return {
        'currentRange': currentRange,
        'maxRange': maxRange,
      };
    } catch (e) {
      print('📊 Vehicle data error: $e');
      return {'currentRange': 0, 'maxRange': 0};
    }
  }

  // Charging Calculation
  int _calculateChargingTime(double currentRange, double maxRange, double targetPercent) {
    final targetRange = maxRange * (targetPercent / 100);
    final rangeToCharge = targetRange - currentRange;
    
    if (rangeToCharge <= 0) return 0;
    
    // 11kW Ladeleistung: 1 km = 1.15 Minuten
    final baseMinutes = (rangeToCharge * 1.15).round();
    
    // Buffer: 1 Minute pro 15 Minuten
    final bufferMinutes = (baseMinutes / 15).ceil();
    
    final totalMinutes = baseMinutes + bufferMinutes;
    return totalMinutes > 600 ? 600 : totalMinutes;
  }

  // UI Actions
  Future<void> _openAuto() async {
    setState(() => _showStartMenu = false);
    await _main.loadRequest(Uri.parse(startVehicleUrl));

    // Prüfen ob wir auf der Login-Seite sind
    final currentUrl = await _main.currentUrl();
    if (currentUrl != null && await _isB2CLoginDom()) {
      setState(() => _showStartMenu = true);
      return;
    }

    // Warten bis Seite geladen ist
    await Future.delayed(const Duration(seconds: 3));

    // Fahrzeug-Scanning mit mehreren Versuchen
    List<Map<String, dynamic>> vehicles = [];
    for (int attempt = 0; attempt < 3; attempt++) {
      vehicles = await _scanVehicles();
      if (vehicles.isNotEmpty) break;
      await Future.delayed(const Duration(seconds: 2));
    }

    if (vehicles.isEmpty) {
      setState(() => _showStartMenu = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Keine Fahrzeuge gefunden. Bitte versuchen Sie es später erneut.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Fahrzeug auswählen (erstes verfügbares)
    final selectedVehicle = vehicles.first;
    final success = await _selectVehicle(selectedVehicle);
    
    if (!success) {
      setState(() => _showStartMenu = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fahrzeug konnte nicht ausgewählt werden.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    
    // Fahrzeugdaten laden
    final vehicleData = await _loadVehicleData();
    
    // Charging Sheet anzeigen
    if (mounted) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => ChargingSheet(
          vehicleData: vehicleData,
          onClose: () => setState(() => _showStartMenu = true),
        ),
      );
    }
  }

  Future<void> _handleMenuAction(String value) async {
    switch (value) {
      case 'views':
        await _main.loadRequest(Uri.parse(startViewsUrl));
        break;
      case 'vehicle':
        await _main.loadRequest(Uri.parse(startVehicleUrl));
        break;
      case 'creds':
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const CredentialsScreen()),
          );
        }
        break;
      case 'test_notification':
        await _showNotification('Test', 'Dies ist eine Test-Benachrichtigung');
        break;
      case 'check_status':
        final status = await _detectVehicleStatus();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Status: ${status ?? 'Unbekannt'}')),
          );
        }
        break;
      case 'logout':
        await storage.delete(key: _kUser);
        await storage.delete(key: _kPass);
        await storage.delete(key: _kCookieStore);
        await _main.clearCache();
        
        await _main.loadRequest(
            Uri.parse('https://soleco-optimizer.ch/Account/SignOut'));
        await Future.delayed(const Duration(milliseconds: 1000));
        await _main.loadRequest(Uri.parse(startVehicleUrl));
        _didAutoLogin = false;
        setState(() {
          _isLoggedIn = false;
          _showStartMenu = false; // Verstecken nach Logout
        });
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco Optimizer'),
        actions: [
          // Nur Startmenü-Button anzeigen wenn eingeloggt
          if (_isLoggedIn)
            IconButton(
              tooltip: 'Startmenü',
              onPressed: () => setState(() => _showStartMenu = !_showStartMenu),
              icon: const Icon(Icons.local_florist_outlined, color: Brand.primary),
            ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'views', child: Text('Zu Ansichten')),
              PopupMenuItem(value: 'vehicle', child: Text('Zu Fahrzeuge')),
              PopupMenuItem(value: 'creds', child: Text('Login speichern/ändern')),
              PopupMenuItem(value: 'test_notification', child: Text('Test Benachrichtigung')),
              PopupMenuItem(value: 'check_status', child: Text('Status prüfen')),
              PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _main),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Brand.primary),
            ),
        ],
      ),
      // Nur FloatingActionButton anzeigen wenn eingeloggt und StartMenu versteckt
      floatingActionButton: (_isLoggedIn && !_showStartMenu)
          ? FloatingActionButton.extended(
              onPressed: () => setState(() => _showStartMenu = true),
              backgroundColor: Brand.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.home),
              label: const Text('Start'),
            )
          : null,
      // Nur StartMenu anzeigen wenn eingeloggt
      bottomSheet: (_isLoggedIn && _showStartMenu)
          ? DraggableScrollableSheet(
              initialChildSize: 0.35,
              minChildSize: 0.2,
              maxChildSize: 0.6,
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.black12,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scrollController,
                          child: StartMenu(
                            onClose: () => setState(() => _showStartMenu = false),
                            onAuto: _openAuto,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            )
          : null,
    );
  }
}

// StartMenu Widget
class StartMenu extends StatelessWidget {
  final VoidCallback? onClose;
  final VoidCallback? onAuto;

  const StartMenu({
    super.key,
    this.onClose,
    this.onAuto,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(blurRadius: 24, color: Colors.black12, offset: Offset(0, 8))
          ],
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Schnellstart',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Brand.primary,
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _RoundAction(
                  label: 'Auto',
                  icon: Icons.ev_station,
                  onTap: onAuto,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _RoundAction({
    required this.label,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(120),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Brand.primary, Brand.primaryDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: const [
                  BoxShadow(
                      blurRadius: 24, color: Colors.black26, offset: Offset(0, 10)),
                ],
              ),
              child: Icon(icon, size: 46, color: Colors.white),
            ),
            const SizedBox(height: 10),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// Charging Sheet
class ChargingSheet extends StatefulWidget {
  final Map<String, double> vehicleData;
  final VoidCallback? onClose;

  const ChargingSheet({
    super.key,
    required this.vehicleData,
    this.onClose,
  });

  @override
  State<ChargingSheet> createState() => _ChargingSheetState();
}

class _ChargingSheetState extends State<ChargingSheet>
    with TickerProviderStateMixin {
  late TabController _tabController;
  double _chargePercent = 80.0;
  bool _isCharging = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  int _calculateChargingTime() {
    final currentRange = widget.vehicleData['currentRange'] ?? 0;
    final maxRange = widget.vehicleData['maxRange'] ?? 0;
    
    if (maxRange == 0) return 0;
    
    final targetRange = maxRange * (_chargePercent / 100);
    final rangeToCharge = targetRange - currentRange;
    
    if (rangeToCharge <= 0) return 0;
    
    final baseMinutes = (rangeToCharge * 1.15).round();
    final bufferMinutes = (baseMinutes / 15).ceil();
    
    final totalMinutes = baseMinutes + bufferMinutes;
    return totalMinutes > 600 ? 600 : totalMinutes;
  }

  @override
  Widget build(BuildContext context) {
    final currentRange = widget.vehicleData['currentRange'] ?? 0;
    final maxRange = widget.vehicleData['maxRange'] ?? 0;
    final chargingTime = _calculateChargingTime();

    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Ladung starten',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Brand.primary,
                  ),
                ),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          
          // Tabs
          TabBar(
            controller: _tabController,
            labelColor: Brand.primary,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Brand.primary,
            tabs: const [
              Tab(text: 'Geplant'),
              Tab(text: 'Schnellladung'),
            ],
          ),
          
          // Tab Content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Planned Charging (Coming Soon)
                const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.schedule, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'Coming Soon',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Geplante Ladung wird in einer\nzukünftigen Version verfügbar sein.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                
                // Quick Charge
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Vehicle Info
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Brand.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Column(
                              children: [
                                const Text('Aktuelle Reichweite', style: TextStyle(fontSize: 12)),
                                Text('${currentRange.toInt()} km', 
                                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Column(
                              children: [
                                const Text('Max. Reichweite', style: TextStyle(fontSize: 12)),
                                Text('${maxRange.toInt()} km', 
                                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 32),
                      
                      // Charge Slider
                      Text(
                        'Ladung bis ${_chargePercent.toInt()}%',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      
                      const SizedBox(height: 16),
                      
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Brand.primary,
                          inactiveTrackColor: Brand.primary.withOpacity(0.3),
                          thumbColor: Brand.primary,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 18),
                          trackHeight: 10,
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 30),
                        ),
                        child: Slider(
                          value: _chargePercent,
                          min: 0,
                          max: 100,
                          divisions: 100,
                          onChanged: (value) {
                            setState(() {
                              _chargePercent = value;
                            });
                          },
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      
                      // Charging Time
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Brand.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.access_time, color: Brand.primary),
                            const SizedBox(width: 8),
                            Text(
                              'Geschätzte Ladezeit: ${chargingTime} Minuten',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Brand.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      const Spacer(),
                      
                      // Start Button
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton(
                          onPressed: _isCharging ? null : () {
                            setState(() => _isCharging = true);
                            // Hier würde die tatsächliche Ladung gestartet werden
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) {
                                setState(() => _isCharging = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Ladung gestartet!')),
                                );
                              }
                            });
                          },
                          child: _isCharging
                              ? const CircularProgressIndicator(color: Colors.white)
                              : const Text(
                                  'Ladung starten',
                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Credentials Screen
class CredentialsScreen extends StatefulWidget {
  const CredentialsScreen({super.key});

  @override
  State<CredentialsScreen> createState() => _CredentialsScreenState();
}

class _CredentialsScreenState extends State<CredentialsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadCredentials();
  }

  Future<void> _loadCredentials() async {
    final user = await _storage.read(key: 'soleco_user');
    final pass = await _storage.read(key: 'soleco_pass');
    
    if (mounted) {
      setState(() {
        _userController.text = user ?? '';
        _passController.text = pass ?? '';
      });
    }
  }

  Future<void> _saveCredentials() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _loading = true);
    
    try {
      await _storage.write(key: 'soleco_user', value: _userController.text);
      await _storage.write(key: 'soleco_pass', value: _passController.text);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Login-Daten gespeichert')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login-Daten'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _userController,
                decoration: const InputDecoration(
                  labelText: 'Benutzername',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Bitte geben Sie einen Benutzernamen ein';
                  }
                  return null;
                },
              ),
              
              const SizedBox(height: 16),
              
              TextFormField(
                controller: _passController,
                decoration: const InputDecoration(
                  labelText: 'Passwort',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Bitte geben Sie ein Passwort ein';
                  }
                  return null;
                },
              ),
              
              const SizedBox(height: 32),
              
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _loading ? null : _saveCredentials,
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          'Speichern',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
