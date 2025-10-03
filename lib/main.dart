import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Notification Service
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = 
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    // Initialize notifications
    await _initializeNotifications();
  } catch (e) {
    print('Notification initialization error: $e');
    // App läuft weiter ohne Notifications
  }
  
  runApp(const OptimizerApp());
}

// Initialize notifications
Future<void> _initializeNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

/// Brandfarben – Kolibri (Orange als Primär, Petrol als Akzent)
class Brand {
  static const Color primary = Color(0xFFF28C00); // Kolibri-Orange
  static const Color primaryDark = Color(0xFFCC7600);
  static const Color petrol = Color(0xFF155D78);
  static const Color surface = Color(0xFFF7F8FA);
}

class OptimizerApp extends StatelessWidget {
  const OptimizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.primary,
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Optimizer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme.copyWith(
          primary: Brand.primary,
          secondary: Brand.petrol,
          surface: Brand.surface,
        ),
        scaffoldBackgroundColor: Brand.surface,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Brand.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const MainApp(),
    );
  }
}

/// ---------------- Secure storage keys ----------------
const _kUser = 'soleco_user';
const _kPass = 'soleco_pass';
const _kCookieStore = 'cookie_store_v1';
const _kSelectedSite = 'selected_site';

/// Kleiner Datentyp für Fahrzeuge
class VehicleItem {
  final String label;
  final int index;
  VehicleItem({required this.label, required this.index});
}

/// Kleiner Datentyp für Sites
class SiteItem {
  final String label;
  final String value;
  SiteItem({required this.label, required this.value});
}

/// ---------------- Haupt-App ohne sichtbare WebView ----------------
class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  final storage = const FlutterSecureStorage();
  final cookieMgr = WebviewCookieManager();

  late final WebViewController _backgroundController; // Unsichtbarer Controller
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _currentSite;
  List<VehicleItem> _vehicles = [];
  List<SiteItem> _sites = [];

  @override
  void initState() {
    super.initState();
    _initBackgroundController();
    _checkLoginStatus();
  }

  void _initBackgroundController() {
    _backgroundController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            print('Background page loaded: $url');
              await _persistCookies(url);

            // Prüfe ob wir eingeloggt sind
            if (url.contains('/VehicleAppointments') || url.contains('/Views')) {
              setState(() => _isLoggedIn = true);
              await _loadSites();
              await _loadVehicles();
            }
          },
        ),
      );
  }

  Future<void> _checkLoginStatus() async {
    final user = await storage.read(key: _kUser);
    final pass = await storage.read(key: _kPass);
    
    if (user != null && pass != null) {
      setState(() => _isLoading = true);
      try {
        await _restoreCookies();
        // Lade zuerst Views-Seite für Site-Auswahl
        await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/Views'));
        
        // Warte und prüfe ob wir automatisch eingeloggt sind
        await Future.delayed(const Duration(seconds: 3));
        final loginSuccess = await _verifyLogin();
        
        if (loginSuccess) {
          setState(() => _isLoggedIn = true);
          await _loadSites();
          // Wechsle dann zu VehicleAppointments für Fahrzeuge
          await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/VehicleAppointments'));
          await Future.delayed(const Duration(seconds: 2));
          await _loadVehicles();
        } else {
          // Automatisches Login fehlgeschlagen - zeige Login-Screen
          setState(() => _isLoggedIn = false);
        }
      } catch (e) {
        print('Auto-login error: $e');
        setState(() => _isLoggedIn = false);
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  // ---------- Cookies ----------
  Future<void> _restoreCookies() async {
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
  }

  Future<void> _persistCookies(String currentUrl) async {
    try {
      final uri = Uri.parse(currentUrl);
      final cookies = await cookieMgr.getCookies(currentUrl);
      final raw = await storage.read(key: _kCookieStore);
      final Map<String, List<Map<String, dynamic>>> store =
          raw == null
              ? {}
              : (jsonDecode(raw) as Map).map(
                  (k, v) => MapEntry(
                    k as String,
                    (v as List).cast<Map>().cast<Map<String, dynamic>>(),
                  ),
                );

      for (final c in cookies) {
        final domain = c.domain ?? uri.host;
        store.putIfAbsent(domain, () => []);
        final list = store[domain]!;
        final idx = list.indexWhere(
            (m) => m['name'] == c.name && m['path'] == (c.path ?? '/'));
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
    } catch (_) {}
  }

  // ---------- Login ----------
  Future<void> _performLogin(String username, String password) async {
    setState(() => _isLoading = true);
    
    try {
      // Lösche alte Cookies um sicherzustellen, dass wir nicht mit alten Sessions arbeiten
      await _backgroundController.clearCache();
      await storage.delete(key: _kCookieStore);
      
      // Speichere Credentials
      await storage.write(key: _kUser, value: username);
      await storage.write(key: _kPass, value: password);
      
      // Lade Login-Seite (Views für Site-Auswahl)
      await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/Views'));
      
      // Warte auf Login-Seite und führe Auto-Login durch
      await Future.delayed(const Duration(seconds: 2));
      await _autoLoginB2C();
      
      // Warte länger und prüfe ob Login erfolgreich war
      await Future.delayed(const Duration(seconds: 4)); // Länger warten
      final loginSuccess = await _verifyLogin();
      
      if (loginSuccess) {
        setState(() => _isLoggedIn = true);
        await _loadSites();
        // Wechsle zu VehicleAppointments für Fahrzeuge
        await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/VehicleAppointments'));
        await Future.delayed(const Duration(seconds: 2));
        await _loadVehicles();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Erfolgreich eingeloggt!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // Login fehlgeschlagen - zurück zum Login
        setState(() => _isLoggedIn = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Login fehlgeschlagen - bitte prüfen Sie Ihre Anmeldedaten'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
      
    } catch (e) {
      print('Login error: $e');
      setState(() => _isLoggedIn = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Login fehlgeschlagen: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------- Login-Verifikation ----------
  Future<bool> _verifyLogin() async {
    try {
      final js = '''
        (function(){
          console.log('🔍 Verifying login...');
          console.log('Current URL:', window.location.href);
          
          // Prüfe ob wir auf der Login-Seite sind (dann ist Login fehlgeschlagen)
          var loginForm = document.getElementById('localAccountForm');
          if (loginForm) {
            console.log('❌ Still on login page - login failed');
            return false;
          }
          
          // Prüfe auf Fehlermeldungen
          var errorElements = document.querySelectorAll('.error, .alert-danger, .validation-summary-errors');
          for (var i = 0; i < errorElements.length; i++) {
            var error = errorElements[i];
            if (error.style.display !== 'none' && error.textContent.trim()) {
              console.log('❌ Found error message:', error.textContent.trim());
              return false;
            }
          }
          
          // Prüfe ob wir auf einer Fehlerseite sind
          var url = window.location.href;
          if (url.includes('error') || url.includes('unauthorized') || url.includes('forbidden')) {
            console.log('❌ On error page - login failed');
            return false;
          }
          
          // Prüfe ob wir auf der Hauptseite sind UND ob die wichtigen Elemente vorhanden sind
          var vehicleSelect = document.getElementById('vehicleSelection');
          var siteSelect = document.getElementById('siteSelection');
          
          // Prüfe ob wir auf der richtigen Domain sind
          if (!url.includes('soleco-optimizer.ch')) {
            console.log('❌ Not on soleco domain - login failed');
            return false;
          }
          
          // Prüfe ob wir auf einer der erwarteten Seiten sind
          if (url.includes('/VehicleAppointments') || url.includes('/Views')) {
            console.log('✅ On correct URL');
            
            // Zusätzliche Prüfung: Suche nach Benutzer-spezifischen Elementen
            var userElements = document.querySelectorAll('[class*="user"], [id*="user"], [class*="profile"], [id*="profile"]');
            var hasUserContent = userElements.length > 0;
            
            // Prüfe ob die Seite vollständig geladen ist (nicht nur Login-Redirect)
            var pageContent = document.body.textContent || '';
            var hasRealContent = pageContent.length > 1000; // Mindestens 1000 Zeichen Inhalt
            
            console.log('Has user elements:', hasUserContent);
            console.log('Has real content:', hasRealContent);
            console.log('Page content length:', pageContent.length);
            
            if (hasRealContent) {
              console.log('✅ Login successful - page has real content');
              return true;
            } else {
              console.log('❌ Login failed - page has no real content');
              return false;
            }
          }
          
          console.log('❌ Login verification failed - not on expected page');
          return false;
        })();
      ''';
      
      final result = await _backgroundController.runJavaScriptReturningResult(js);
      final success = result.toString() == 'true';
      print('Login verification result: $success');
      return success;
    } catch (e) {
      print('Error verifying login: $e');
      return false;
    }
  }

  Future<void> _autoLoginB2C() async {
    final user = await storage.read(key: _kUser);
    final pass = await storage.read(key: _kPass);
    if (user == null || pass == null) return;
    
    final esc = (String s) =>
        s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('`', r'\`');

    final js = '''
      (function(){
        console.log('🔐 Starting auto-login...');
        
        function setVal(el,val){
          if(!el) return false;
          el.focus(); el.value=val;
          try{
            el.dispatchEvent(new Event('input',{bubbles:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            var ev=document.createEvent('HTMLEvents'); ev.initEvent('keyup',true,false); el.dispatchEvent(ev);
          }catch(e){}
          return true;
        }
        
        function tryLogin(){
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var btn=document.getElementById('next');
          
          console.log('Login elements found:', {
            username: !!u,
            password: !!p,
            button: !!btn
          });
          
          if(u&&p&&btn){
            console.log('Setting credentials...');
            setVal(u,'${esc(user)}');
            setVal(p,'${esc(pass)}');
            
            // Prüfe ob die Werte wirklich gesetzt wurden
            var usernameSet = u.value === '${esc(user)}';
            var passwordSet = p.value === '${esc(pass)}';
            
            console.log('Credentials set:', {
              username: usernameSet,
              password: passwordSet
            });
            
            if (usernameSet && passwordSet) {
              console.log('Clicking login button...');
            btn.click();
            return true;
            } else {
              console.log('❌ Failed to set credentials properly');
              return false;
            }
          }
          return false;
        }
        
        if(!tryLogin()){
          console.log('🔄 Retrying login...');
          var tries=0;
          var t=setInterval(function(){ 
            tries++; 
            if(tryLogin()||tries>50){
              clearInterval(t);
              console.log('Login attempt finished after', tries, 'tries');
            } 
          },100);
        }
      })();
    ''';
    await _backgroundController.runJavaScript(js);
  }

  // ---------- Sites laden ----------
  Future<void> _loadSites() async {
    final js = '''
      (function(){
        console.log('🔍 Loading sites from Views page...');
        
        // Suche nach dem siteSelection Element
        var siteSelect = document.getElementById('siteSelection');
        console.log('Site selection element found:', !!siteSelect);
        
        if(!siteSelect) {
          console.log('❌ No siteSelection element found');
          return JSON.stringify({ok: false, sites: [], reason: 'no_element'});
        }
        
        var sites = [];
        
        // DevExtreme SelectBox Methode
        try {
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(siteSelect).dxSelectBox('instance');
            if(inst){
              console.log('✅ Found DevExtreme SelectBox instance');
              
              var items = inst.option('items') || inst.option('dataSource');
              console.log('Items/DataSource:', items);
              
              if(Array.isArray(items)){
                for(var i = 0; i < items.length; i++){
                  var item = items[i];
                  var label = item.text || item.name || item.label || item.value || ('Site ' + (i+1));
                  var value = item.value || item.id || item.text || label;
                  sites.push({label: label, value: value});
                  console.log('Added site:', label, value);
                }
              }
            }
          }
        } catch(e) {
          console.log('❌ DevExtreme method failed:', e);
        }
        
        // Fallback: DOM scraping
        if(sites.length === 0){
          console.log('🔄 Trying DOM scraping fallback...');
          
          // Suche nach Optionen im Select
          var options = siteSelect.querySelectorAll('option');
          console.log('Found options:', options.length);
          
          for(var i = 0; i < options.length; i++){
            var opt = options[i];
            if(opt.value && opt.textContent.trim()) {
              sites.push({label: opt.textContent.trim(), value: opt.value});
              console.log('Added site from option:', opt.textContent.trim(), opt.value);
            }
          }
          
          // Fallback: Suche nach Dropdown-Items
          if(sites.length === 0) {
            var dropdownItems = document.querySelectorAll('.dx-selectbox-popup .dx-item .dx-item-content');
            console.log('Found dropdown items:', dropdownItems.length);
            
            for(var i = 0; i < dropdownItems.length; i++){
              var item = dropdownItems[i];
              var text = item.textContent.trim();
              if(text) {
                sites.push({label: text, value: text});
                console.log('Added site from dropdown:', text);
              }
            }
          }
        }
        
        console.log('✅ Total sites found:', sites.length);
        return JSON.stringify({ok: true, sites: sites});
      })();
    ''';

    try {
      final result = await _backgroundController.runJavaScriptReturningResult(js);
      final jsonStr = result is String ? result : result.toString();
      final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      print('Site loading result: $obj');
      
      if (obj['ok'] == true) {
        final sitesList = (obj['sites'] as List).cast<Map<String, dynamic>>();
        setState(() {
          _sites = sitesList.map((s) => SiteItem(
            label: s['label'] as String,
            value: s['value'] as String,
          )).toList();
        });
        
        print('Loaded ${_sites.length} sites: ${_sites.map((s) => s.label).join(', ')}');
        
        // Lade gespeicherte Site
        final savedSite = await storage.read(key: _kSelectedSite);
        if (savedSite != null && _sites.any((s) => s.value == savedSite)) {
          _currentSite = savedSite;
        } else if (_sites.isNotEmpty) {
          _currentSite = _sites.first.value;
        }
      } else {
        print('Failed to load sites: ${obj['reason']}');
      }
    } catch (e) {
      print('Error loading sites: $e');
    }
  }

  // ---------- Site wechseln ----------
  Future<void> _switchSite(String siteValue) async {
    setState(() => _isLoading = true);
    
    try {
      // Wechsle zuerst zur Views-Seite für Site-Auswahl
      await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/Views'));
      await Future.delayed(const Duration(seconds: 2));
    
    final js = '''
      (function(){
          console.log('🔄 Switching to site: $siteValue');
          
          var siteSelect = document.getElementById('siteSelection');
          if(!siteSelect) {
            console.log('❌ No siteSelection element found');
          return 'no_element';
        }

          // DevExtreme SelectBox
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(siteSelect).dxSelectBox('instance');
            if(inst){
              console.log('✅ Found DevExtreme instance, setting value');
              inst.option('value', '$siteValue');
                  inst.option('opened', false);
                  
              // Trigger change event
                  var changeEvent = new Event('change', { bubbles: true });
              siteSelect.dispatchEvent(changeEvent);
              
              console.log('✅ Site changed via DevExtreme');
                  return 'success';
            }
          }
          
          // Fallback: DOM
          var select = siteSelect.querySelector('select');
          if(select){
            select.value = '$siteValue';
            var changeEvent = new Event('change', { bubbles: true });
            select.dispatchEvent(changeEvent);
            console.log('✅ Site changed via DOM');
            return 'success_dom';
          }
          
          console.log('❌ Failed to change site');
        return 'failed';
      })();
    ''';

      await _backgroundController.runJavaScript(js);
      setState(() => _currentSite = siteValue);
      await storage.write(key: _kSelectedSite, value: siteValue);
      
      // Warte auf Datenaktualisierung und wechsle dann zu VehicleAppointments
      await Future.delayed(const Duration(seconds: 2));
      await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/VehicleAppointments'));
      await Future.delayed(const Duration(seconds: 2));
      await _loadVehicles();
      
    } catch (e) {
      print('Error switching site: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------- Fahrzeuge laden ----------
  Future<void> _loadVehicles() async {
    final js = '''
        (function(){
        console.log('🚗 Loading vehicles from VehicleAppointments page...');
        console.log('Current URL:', window.location.href);
        
        var vehicleSelect = document.getElementById('vehicleSelection');
        console.log('Vehicle selection element found:', !!vehicleSelect);
        
        if(!vehicleSelect) {
          console.log('❌ No vehicleSelection element found');
          return JSON.stringify({ok: false, vehicles: [], reason: 'no_element'});
        }
        
        var vehicles = [];
        
        // DevExtreme SelectBox
        try {
            if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(vehicleSelect).dxSelectBox('instance');
              if(inst){
              console.log('✅ Found DevExtreme SelectBox instance for vehicles');
              
              var items = inst.option('items') || inst.option('dataSource');
              console.log('Vehicle items/DataSource:', items);
              
              if(Array.isArray(items)){
                for(var i = 0; i < items.length; i++){
                  var item = items[i];
                  var label = item.text || item.name || item.label || item.value || ('Vehicle ' + (i+1));
                  vehicles.push({label: label, index: i});
                  console.log('Added vehicle:', label, i);
                  }
                }
              }
            }
          } catch(e) {
          console.log('❌ DevExtreme method failed for vehicles:', e);
        }
        
        // Fallback: DOM scraping
        if(vehicles.length === 0){
          console.log('🔄 Trying DOM scraping fallback for vehicles...');
          
          var options = vehicleSelect.querySelectorAll('option');
          console.log('Found vehicle options:', options.length);
          
          for(var i = 0; i < options.length; i++){
            var opt = options[i];
            if(opt.textContent.trim()) {
              vehicles.push({label: opt.textContent.trim(), index: i});
              console.log('Added vehicle from option:', opt.textContent.trim(), i);
            }
          }
          
          // Fallback: Suche nach Dropdown-Items
          if(vehicles.length === 0) {
            var dropdownItems = document.querySelectorAll('.dx-selectbox-popup .dx-item .dx-item-content');
            console.log('Found vehicle dropdown items:', dropdownItems.length);
            
            for(var i = 0; i < dropdownItems.length; i++){
              var item = dropdownItems[i];
              var text = item.textContent.trim();
              if(text) {
                vehicles.push({label: text, index: i});
                console.log('Added vehicle from dropdown:', text, i);
              }
            }
          }
        }
        
        console.log('✅ Total vehicles found:', vehicles.length);
        return JSON.stringify({ok: true, vehicles: vehicles});
        })();
      ''';
      
    try {
      final result = await _backgroundController.runJavaScriptReturningResult(js);
      final jsonStr = result is String ? result : result.toString();
      final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      print('Vehicle loading result: $obj');
      
      if (obj['ok'] == true) {
        final vehiclesList = (obj['vehicles'] as List).cast<Map<String, dynamic>>();
        setState(() {
          _vehicles = vehiclesList.map((v) => VehicleItem(
            label: v['label'] as String,
            index: v['index'] as int,
          )).toList();
        });
        
        print('Loaded ${_vehicles.length} vehicles: ${_vehicles.map((v) => v.label).join(', ')}');
      } else {
        print('Failed to load vehicles: ${obj['reason']}');
      }
    } catch (e) {
      print('Error loading vehicles: $e');
    }
  }

  // ---------- Fahrzeug auswählen ----------
  Future<void> _selectVehicle(VehicleItem vehicle) async {
    setState(() => _isLoading = true);
    
    final js = '''
      (function(){
        var vehicleSelect = document.getElementById('vehicleSelection');
        if(!vehicleSelect) return 'no_element';
        
        var idx = ${vehicle.index};
        
        // DevExtreme SelectBox
        if(window.jQuery && jQuery.fn.dxSelectBox){
          var inst = jQuery(vehicleSelect).dxSelectBox('instance');
          if(inst){
            inst.option('selectedIndex', idx);
            inst.option('opened', false);
            
            // Trigger change event
            var changeEvent = new Event('change', { bubbles: true });
            vehicleSelect.dispatchEvent(changeEvent);
            
            return 'success';
          }
        }
        
        // Fallback: DOM
        var select = vehicleSelect.querySelector('select');
        if(select && select.options[idx]){
          select.selectedIndex = idx;
          var changeEvent = new Event('change', { bubbles: true });
          select.dispatchEvent(changeEvent);
          return 'success_dom';
        }
        
        return 'failed';
      })();
    ''';
    
    try {
      await _backgroundController.runJavaScript(js);
      
      // Warte auf Datenaktualisierung
      await Future.delayed(const Duration(seconds: 2));
      
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fahrzeug "${vehicle.label}" ausgewählt')),
        );
      }
      
    } catch (e) {
      print('Error selecting vehicle: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------- Ladevorgang starten ----------
  Future<void> _startCharging(int minutes) async {
    setState(() => _isLoading = true);
    
    final js = '''
      (function(){
        function toNum(x){var n=parseFloat(x); return isNaN(n)?0:n;}
        var m = toNum("$minutes");

        try {
          if (window.DevExpress && window.jQuery) {
            var form = jQuery("#parameterform").dxForm("instance");
            if (form) {
              var eMin = form.getEditor("Minutes");
              if (eMin) { try { eMin.option("value", m); } catch(e){} }
              try { form.updateData("Minutes", m); } catch(e){} }
              
          var btn = document.querySelector("#PostParametersButton");
          if (btn) {
            try { if (window.jQuery) jQuery(btn).trigger('dxclick'); } catch(e){}
            try { btn.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true})); } catch(e){}
            try { btn.dispatchEvent(new MouseEvent('pointerup',{bubbles:true})); } catch(e){}
            try { btn.click(); } catch(e){}
            return "clicked";
              }
            }
          }
        } catch(e){}

        return "fail";
      })();
    ''';
    
    try {
      await _backgroundController.runJavaScript(js);
      
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ladevorgang gestartet (${minutes} min)')),
        );
      }
      
    } catch (e) {
      print('Error starting charging: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------- Logout ----------
  Future<void> _logout() async {
                await storage.delete(key: _kUser);
                await storage.delete(key: _kPass);
                await storage.delete(key: _kCookieStore);
    await storage.delete(key: _kSelectedSite);
    await _backgroundController.clearCache();
    
    setState(() {
      _isLoggedIn = false;
      _vehicles.clear();
      _sites.clear();
      _currentSite = null;
    });
    
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Abgemeldet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Zeige Loading-Screen beim App-Start
    if (_isLoading && !_isLoggedIn) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Brand.primary, Brand.primaryDark],
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
        children: [
                CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
                SizedBox(height: 24),
                Text(
                  'Lade App...',
                  style: TextStyle(
                color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_isLoggedIn) {
      return LoginScreen(onLogin: _performLogin, isLoading: _isLoading);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Optimizer', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') _logout();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
                  ),
              ],
            ),
      body: _isLoading
          ? const Center(
        child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
          children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Lade Daten...'),
                ],
              ),
            )
          : MainScreen(
              sites: _sites,
              currentSite: _currentSite,
              vehicles: _vehicles,
              onSiteChanged: _switchSite,
              onVehicleSelected: _selectVehicle,
              onStartCharging: _startCharging,
              onRefresh: () async {
                await _loadVehicles();
              },
      ),
    );
  }
}

/// ---------------- Login Screen ----------------
class LoginScreen extends StatefulWidget {
  final Future<void> Function(String username, String password) onLogin;
  final bool isLoading;

  const LoginScreen({
    super.key, 
    required this.onLogin,
    required this.isLoading,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Brand.primary, Brand.primaryDark],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(32),
        child: Form(
                    key: _formKey,
          child: Column(
                      mainAxisSize: MainAxisSize.min,
            children: [
                        // Logo/Icon
            Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            color: Brand.primary,
                shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.ev_station,
                            size: 40,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 24),
                        
                        // Title
                        const Text(
                          'Soleco Optimizer',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Brand.petrol,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Mit Benutzername anmelden',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 32),
                        
                        // Username Field
              TextFormField(
                          controller: _usernameController,
                decoration: const InputDecoration(
                            labelText: 'Benutzername',
                            prefixIcon: Icon(Icons.person),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Benutzername erforderlich';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        
                        // Password Field
              TextFormField(
                          controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                            labelText: 'Kennwort',
                            prefixIcon: Icon(Icons.lock),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Kennwort erforderlich';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 24),
                        
                        // Login Button
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: widget.isLoading ? null : () {
                              if (_formKey.currentState!.validate()) {
                                widget.onLogin(
                                  _usernameController.text.trim(),
                                  _passwordController.text,
                                );
                              }
                            },
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                            child: widget.isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                    ),
                                  )
                                : const Text('Anmelden'),
                          ),
              ),
              const SizedBox(height: 16),
                        
                        // Register Link
                        TextButton(
                          onPressed: () {
                            // TODO: Implement registration
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Registrierung noch nicht verfügbar')),
                            );
                          },
                          child: const Text('Sie haben noch kein Konto? Jetzt registrieren'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ---------------- Main Screen ----------------
class MainScreen extends StatefulWidget {
  final List<SiteItem> sites;
  final String? currentSite;
  final List<VehicleItem> vehicles;
  final Future<void> Function(String siteValue) onSiteChanged;
  final Future<void> Function(VehicleItem vehicle) onVehicleSelected;
  final Future<void> Function(int minutes) onStartCharging;
  final Future<void> Function() onRefresh;

  const MainScreen({
    super.key,
    required this.sites,
    required this.currentSite,
    required this.vehicles,
    required this.onSiteChanged,
    required this.onVehicleSelected,
    required this.onStartCharging,
    required this.onRefresh,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  VehicleItem? _selectedVehicle;
  int _chargingMinutes = 180;
  bool _isCharging = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Site Selection
          if (widget.sites.isNotEmpty) ...[
            const Text(
              'Anlage auswählen',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                    const Text(
                      'Aktuelle Anlage:',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: widget.currentSite,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_on),
                      ),
                      items: widget.sites.map((site) => 
                        DropdownMenuItem(
                          value: site.value,
                          child: Text(site.label),
                        ),
                      ).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          widget.onSiteChanged(value);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
          
          // Vehicle Selection
          Row(
        children: [
              const Text(
                'Fahrzeugauswahl',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh),
                tooltip: 'Aktualisieren',
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Vehicle List
          Expanded(
            child: widget.vehicles.isEmpty
                ? Center(
            child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
              children: [
                        Icon(
                          Icons.directions_car_outlined,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                Text(
                          'Keine Fahrzeuge gefunden',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                          ),
                        ),
                const SizedBox(height: 8),
                        Text(
                          widget.sites.isEmpty 
                              ? 'Bitte warten Sie, bis die Anlagen geladen sind'
                              : 'Bitte wählen Sie zuerst eine Anlage aus',
                          style: TextStyle(
                            color: Colors.grey[500],
                          ),
                          textAlign: TextAlign.center,
                ),
              ],
            ),
                  )
                : ListView.builder(
                    itemCount: widget.vehicles.length,
                    itemBuilder: (context, index) {
                      final vehicle = widget.vehicles[index];
                      final isSelected = _selectedVehicle?.index == vehicle.index;
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: isSelected ? 4 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isSelected ? Brand.primary : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isSelected ? Brand.primary : Colors.grey[300],
                            child: Icon(
                              Icons.directions_car,
                              color: isSelected ? Colors.white : Colors.grey[600],
                            ),
                          ),
                          title: Text(
                            vehicle.label,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          trailing: isSelected
                              ? const Icon(Icons.check_circle, color: Brand.primary)
                              : const Icon(Icons.radio_button_unchecked),
                          onTap: () {
                            setState(() => _selectedVehicle = vehicle);
                            widget.onVehicleSelected(vehicle);
        },
      ),
    );
                    },
                  ),
          ),
          
          // Charging Controls
          if (_selectedVehicle != null) ...[
            const SizedBox(height: 24),
          const Text(
              'Ladeeinstellungen',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
            const SizedBox(height: 16),
            
            // Minutes Slider
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ladedauer: $_chargingMinutes Minuten',
                      style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
                    Slider(
                      value: _chargingMinutes.toDouble(),
                      min: 30,
                      max: 600,
                      divisions: 57,
                      label: '$_chargingMinutes min',
                      onChanged: (value) {
                        setState(() => _chargingMinutes = value.round());
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('30 min', style: TextStyle(color: Colors.grey[600])),
                        Text('600 min', style: TextStyle(color: Colors.grey[600])),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Start Charging Button
            SizedBox(
            width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isCharging ? null : () async {
                  setState(() => _isCharging = true);
                  await widget.onStartCharging(_chargingMinutes);
                  setState(() => _isCharging = false);
                },
                icon: _isCharging
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(Icons.flash_on),
                label: Text(_isCharging ? 'Starte Ladevorgang...' : 'Ladevorgang starten'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          ],
        ],
      ),
    );
  }
}

/// ---------------- Vehicle Screen (Legacy - wird nicht mehr verwendet) ----------------
class VehicleScreen extends StatefulWidget {
  final List<VehicleItem> vehicles;
  final Future<void> Function(VehicleItem vehicle) onVehicleSelected;
  final Future<void> Function(int minutes) onStartCharging;
  final Future<void> Function() onRefresh;

  const VehicleScreen({
    super.key,
    required this.vehicles,
    required this.onVehicleSelected,
    required this.onStartCharging,
    required this.onRefresh,
  });

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  VehicleItem? _selectedVehicle;
  int _chargingMinutes = 180;
  bool _isCharging = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Text(
                'Fahrzeugauswahl',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh),
                tooltip: 'Aktualisieren',
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Vehicle List
          if (widget.vehicles.isEmpty)
            Expanded(
              child: Center(
            child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
              children: [
                    Icon(
                      Icons.directions_car_outlined,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Keine Fahrzeuge gefunden',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.grey[600],
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                      'Bitte wählen Sie zuerst eine Anlage aus',
                  style: TextStyle(
                        color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: widget.vehicles.length,
                itemBuilder: (context, index) {
                  final vehicle = widget.vehicles[index];
                  final isSelected = _selectedVehicle?.index == vehicle.index;
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: isSelected ? 4 : 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isSelected ? Brand.primary : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isSelected ? Brand.primary : Colors.grey[300],
                        child: Icon(
                          Icons.directions_car,
                          color: isSelected ? Colors.white : Colors.grey[600],
                        ),
                      ),
                      title: Text(
                        vehicle.label,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Brand.primary)
                          : const Icon(Icons.radio_button_unchecked),
                      onTap: () {
                        setState(() => _selectedVehicle = vehicle);
                        widget.onVehicleSelected(vehicle);
                      },
                    ),
                  );
                },
              ),
            ),
          
          // Charging Controls
          if (_selectedVehicle != null) ...[
          const SizedBox(height: 24),
            const Text(
              'Ladeeinstellungen',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            // Minutes Slider
            Card(
              child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'Ladedauer: $_chargingMinutes Minuten',
                    style: const TextStyle(
                      fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Slider(
                      value: _chargingMinutes.toDouble(),
                      min: 30,
                      max: 600,
                      divisions: 57,
                      label: '$_chargingMinutes min',
                      onChanged: (value) {
                        setState(() => _chargingMinutes = value.round());
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('30 min', style: TextStyle(color: Colors.grey[600])),
                        Text('600 min', style: TextStyle(color: Colors.grey[600])),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
          const SizedBox(height: 16),
            
            // Start Charging Button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
                onPressed: _isCharging ? null : () async {
                  setState(() => _isCharging = true);
                  await widget.onStartCharging(_chargingMinutes);
                  setState(() => _isCharging = false);
                },
                icon: _isCharging
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(Icons.flash_on),
                label: Text(_isCharging ? 'Starte Ladevorgang...' : 'Ladevorgang starten'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          ],
        ],
      ),
    );
  }
}
