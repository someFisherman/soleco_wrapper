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

  late final WebViewController _backgroundController; // Komplett unsichtbarer Controller
  late final WebViewController _loginController; // Sichtbarer Controller für Login
  bool _isLoggedIn = false;
  bool _isLoading = false;
  bool _showLoginWebView = false; // Steuert ob Login-WebView sichtbar ist
  bool _isLoggingIn = false; // Steuert ob "Logging in..." Screen angezeigt wird
  String? _currentSite;
  List<VehicleItem> _vehicles = [];
  List<SiteItem> _sites = [];

  @override
  void initState() {
    super.initState();
    _initBackgroundController();
    _initLoginController();
    _startLoginProcess();
  }

  void _initBackgroundController() {
    _backgroundController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..enableZoom(false)
      ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            print('Background page loaded: $url');
              await _persistCookies(url);
            // WebView läuft nur noch im Hintergrund - keine UI-Updates mehr
          },
        ),
      );
  }

  void _initLoginController() {
    _loginController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..enableZoom(false)
      ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36')
      ..addJavaScriptChannel('showLoggingIn', onMessageReceived: (message) {
        print('🎯 JavaScript Channel received: $message');
        setState(() {
          _showLoginWebView = false;
          _isLoggingIn = true;
        });
      })
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            print('🔍 Page started loading: $url');
            
            // Wenn wir von B2C zu soleco-optimizer.ch wechseln, zeige "Logging in..."
            if (url.contains('soleco-optimizer.ch') && 
                !url.contains('b2clogin.com') && 
                !url.contains('AzureADB2C') && 
                !url.contains('Account/SignIn') &&
                !url.contains('signin-oidc') &&
                !url.contains('MicrosoftIdentity')) {
              
              print('✅ Login successful - switching to logging in screen');
              setState(() => _showLoginWebView = false);
              setState(() => _isLoggingIn = true);
            } else {
              print('❌ Still on login page or redirect page');
            }
          },
          onPageFinished: (url) async {
            print('Login page loaded: $url');
            await _persistCookies(url);
            
            // JavaScript Event-Listener für sofortigen UI-Wechsel injizieren
            await _injectLoginButtonListener();
            
            // Prüfe ob Login erfolgreich war - erweiterte Erkennung
            if (url.contains('soleco-optimizer.ch') && 
                !url.contains('b2clogin.com') && 
                !url.contains('AzureADB2C') && 
                !url.contains('Account/SignIn') &&
                !url.contains('signin-oidc') &&
                !url.contains('MicrosoftIdentity') &&
                (url.contains('/VehicleAppointments') || 
                 url.contains('/Views') || 
                 url.contains('/Dashboard') ||
                 url.contains('/Settings'))) {
              
              // Login erfolgreich - lade Daten
              setState(() => _isLoggingIn = false);
              setState(() => _isLoggedIn = true);
              setState(() => _isLoading = true);
              
              // Kopiere Cookies zum Background Controller
              await _copyCookiesToBackground();
              
              // Lade Daten im Hintergrund
              print('Loading sites...');
              await _loadSites();
              print('Sites loaded: ${_sites.length}');
              
              print('Loading vehicles...');
              await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/VehicleAppointments'));
              await Future.delayed(const Duration(seconds: 3));
              
              // Öffne das Dropdown um Fahrzeuge zu laden
              await _openVehicleDropdown();
              await Future.delayed(const Duration(seconds: 1));
              await _loadVehicles();
              print('Vehicles loaded: ${_vehicles.length}');
              
              setState(() => _isLoading = false);
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Erfolgreich eingeloggt!'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            }
            // Bei fehlgeschlagenem Login bleibt WebView sichtbar
          },
        ),
      );
  }

  Future<void> _startLoginProcess() async {
    // Starte direkt mit Login-WebView
    setState(() => _showLoginWebView = true);
    await _loginController.loadRequest(Uri.parse('https://soleco-optimizer.ch/AzureADB2C/Account/SignIn'));
  }

  // ---------- JavaScript Event-Listener für Login-Button ----------
  Future<void> _injectLoginButtonListener() async {
    try {
      await _loginController.runJavaScript('''
        (function() {
          console.log('🎯 Injecting login button listener...');
          
          // Entferne alte Event-Listener falls vorhanden
          if (window.loginButtonListener) {
            document.removeEventListener('click', window.loginButtonListener);
          }
          
          // Neuer Event-Listener für alle Klicks
          window.loginButtonListener = function(e) {
            var target = e.target;
            var text = target.textContent || target.value || '';
            var type = target.type || '';
            var className = target.className || '';
            var id = target.id || '';
            
            console.log('🔍 Click detected:', {
              text: text,
              type: type,
              className: className,
              id: id
            });
            
            // Prüfe auf Login-Button-Indikatoren
            var isLoginButton = (
              text.toLowerCase().includes('anmelden') || 
              text.toLowerCase().includes('sign in') ||
              text.toLowerCase().includes('login') ||
              text.toLowerCase().includes('einloggen') ||
              type === 'submit' ||
              className.toLowerCase().includes('login') ||
              className.toLowerCase().includes('signin') ||
              id.toLowerCase().includes('login') ||
              id.toLowerCase().includes('signin') ||
              target.closest('form') !== null
            );
            
            if (isLoginButton) {
              console.log('✅ Login button clicked - triggering immediate UI switch');
              
              // SOFORTIGER UI-Wechsel über JavaScript Channel
              if (window.showLoggingIn) {
                window.showLoggingIn.postMessage('show');
              }
              
              // Verhindere weitere Event-Propagation
              e.stopImmediatePropagation();
              return false;
            }
          };
          
          // Event-Listener hinzufügen (capture phase für frühere Erkennung)
          document.addEventListener('click', window.loginButtonListener, true);
          
          console.log('✅ Login button listener injected successfully');
        })();
      ''');
    } catch (e) {
      print('Error injecting login button listener: $e');
    }
  }

  // ---------- Cookies ----------
  Future<void> _copyCookiesToBackground() async {
    try {
      // Kopiere alle Cookies vom Login-Controller zum Background-Controller
      final cookies = await cookieMgr.getCookies('https://soleco-optimizer.ch');
      for (final cookie in cookies) {
        await cookieMgr.setCookies([cookie]);
      }
      print('Cookies copied to background controller');
    } catch (e) {
      print('Error copying cookies: $e');
    }
  }

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


  // ---------- Login-Verifikation ----------
  Future<bool> _verifyLogin() async {
    try {
      final js = '''
        (function(){
          console.log('🔍 Verifying login...');
          var url = window.location.href;
          console.log('Current URL:', url);
          
          // STRENGE Prüfung: Sind wir noch auf B2C-Login-Seiten?
          if (url.includes('b2clogin.com') || url.includes('AzureADB2C') || url.includes('Account/SignIn')) {
            console.log('❌ Still on B2C login page - login failed');
            return false;
          }
          
          // Prüfe ob Login-Formular noch vorhanden ist
          var loginForm = document.getElementById('localAccountForm');
          if (loginForm) {
            console.log('❌ Login form still present - login failed');
            return false;
          }
          
          // Prüfe auf Fehlermeldungen (erweiterte Suche)
          var errorSelectors = [
            '.error', '.alert-danger', '.validation-summary-errors', '.pageLevel',
            '.error-message', '.alert', '.warning', '.danger',
            '[class*="error"]', '[class*="alert"]', '[class*="warning"]'
          ];
          
          for (var i = 0; i < errorSelectors.length; i++) {
            var errorElements = document.querySelectorAll(errorSelectors[i]);
            for (var j = 0; j < errorElements.length; j++) {
              var error = errorElements[j];
              if (error.style.display !== 'none' && error.textContent.trim()) {
                var errorText = error.textContent.trim().toLowerCase();
                // Ignoriere leere oder irrelevante Fehlermeldungen
                if (errorText.length > 5 && !errorText.includes('loading') && !errorText.includes('please wait')) {
                  console.log('❌ Found error message:', error.textContent.trim());
                  return false;
                }
              }
            }
          }
          
          // Prüfe ob wir auf einer Fehlerseite sind
          if (url.includes('error') || url.includes('unauthorized') || url.includes('forbidden') || url.includes('access denied')) {
            console.log('❌ On error page - login failed');
            return false;
          }
          
          // Prüfe ob wir auf der richtigen Domain sind
          if (!url.includes('soleco-optimizer.ch')) {
            console.log('❌ Not on soleco domain - login failed');
            return false;
          }
          
          // NUR wenn wir wirklich auf der Hauptseite sind
          if (url.includes('/VehicleAppointments') || url.includes('/Views')) {
            console.log('✅ On correct URL');
            
            // Prüfe ob die Seite vollständig geladen ist
            var pageContent = document.body.textContent || '';
            var hasRealContent = pageContent.length > 3000; // Noch höhere Anforderung
            
            // Prüfe ob wichtige Elemente vorhanden sind
            var vehicleSelect = document.getElementById('vehicleSelection');
            var siteSelect = document.getElementById('siteSelection');
            var hasImportantElements = vehicleSelect || siteSelect;
            
            // Zusätzliche Prüfung: Suche nach spezifischen Inhalten
            var hasSpecificContent = pageContent.includes('Fahrzeug') || 
                                   pageContent.includes('Vehicle') || 
                                   pageContent.includes('Anlage') || 
                                   pageContent.includes('Site');
            
            console.log('Page content length:', pageContent.length);
            console.log('Has important elements:', hasImportantElements);
            console.log('Has real content:', hasRealContent);
            console.log('Has specific content:', hasSpecificContent);
            
            // NUR wenn ALLE Bedingungen erfüllt sind
            if (hasRealContent && hasImportantElements && hasSpecificContent) {
              console.log('✅ Login successful - page has real content and elements');
              return true;
            } else {
              console.log('❌ Login failed - page incomplete or missing content');
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

  // ---------- Fahrzeug-Dropdown öffnen ----------
  Future<void> _openVehicleDropdown() async {
    final js = '''
      (function(){
        console.log('🔽 Opening vehicle dropdown...');
        
        var vehicleSelect = document.getElementById('vehicleSelection');
        if(!vehicleSelect) {
          console.log('❌ No vehicleSelection element found');
          return 'no_element';
        }
        
        // DevExtreme SelectBox öffnen
        try {
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(vehicleSelect).dxSelectBox('instance');
            if(inst){
              console.log('✅ Found DevExtreme instance, opening dropdown');
              inst.open();
              return 'success';
            }
          }
        } catch(e) {
          console.log('❌ DevExtreme open failed:', e);
        }
        
        // Fallback: Klick auf Dropdown-Button
        try {
          var dropdownButton = vehicleSelect.querySelector('.dx-dropdowneditor-button');
          if(dropdownButton) {
            console.log('✅ Clicking dropdown button');
            dropdownButton.click();
            return 'success_click';
          }
        } catch(e) {
          console.log('❌ Click failed:', e);
        }
        
        console.log('❌ Failed to open dropdown');
        return 'failed';
      })();
    ''';
    
    try {
      await _backgroundController.runJavaScript(js);
    } catch (e) {
      print('Error opening vehicle dropdown: $e');
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
        
        // DevExtreme SelectBox - erweiterte Methode
        try {
            if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(vehicleSelect).dxSelectBox('instance');
              if(inst){
              console.log('✅ Found DevExtreme SelectBox instance for vehicles');
              
              // Versuche verschiedene Datenquellen
              var items = inst.option('items') || inst.option('dataSource') || inst.option('dataSource.items');
              console.log('Vehicle items/DataSource:', items);
              
              if(Array.isArray(items)){
                for(var i = 0; i < items.length; i++){
                  var item = items[i];
                  var label = item.text || item.name || item.label || item.value || item.displayValue || ('Vehicle ' + (i+1));
                  vehicles.push({label: label, index: i});
                  console.log('Added vehicle:', label, i);
                  }
                } else {
                  // Versuche dataSource direkt zu lesen
                  var dataSource = inst.option('dataSource');
                  if(dataSource && dataSource.items) {
                    console.log('Found dataSource.items:', dataSource.items);
                    for(var i = 0; i < dataSource.items.length; i++){
                      var item = dataSource.items[i];
                      var label = item.text || item.name || item.label || item.value || item.displayValue || ('Vehicle ' + (i+1));
                      vehicles.push({label: label, index: i});
                      console.log('Added vehicle from dataSource:', label, i);
                    }
                  }
                }
              }
            }
          } catch(e) {
          console.log('❌ DevExtreme method failed for vehicles:', e);
        }
        
        // Fallback: DOM scraping - erweiterte Suche
        if(vehicles.length === 0){
          console.log('🔄 Trying DOM scraping fallback for vehicles...');
          
          // Suche nach Dropdown-Items in der Popup
          var dropdownItems = document.querySelectorAll('.dx-selectbox-popup .dx-item .dx-item-content, .dx-selectbox-popup .dx-item-content');
          console.log('Found vehicle dropdown items:', dropdownItems.length);
          
          for(var i = 0; i < dropdownItems.length; i++){
            var item = dropdownItems[i];
            var text = item.textContent.trim();
            if(text && text !== 'Fahrzeug auswählen') {
              vehicles.push({label: text, index: i});
              console.log('Added vehicle from dropdown:', text, i);
            }
          }
          
          // Fallback: Suche nach allen möglichen Optionen
          if(vehicles.length === 0) {
            var allOptions = document.querySelectorAll('option, .dx-item, [role="option"]');
            console.log('Found all options:', allOptions.length);
            
            for(var i = 0; i < allOptions.length; i++){
              var opt = allOptions[i];
              var text = opt.textContent.trim();
              if(text && text !== 'Fahrzeug auswählen' && text.length > 0) {
                vehicles.push({label: text, index: i});
                console.log('Added vehicle from option:', text, i);
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
    try {
      // Verwende den echten SignOut-Link der Webseite (im Hintergrund)
      await _backgroundController.loadRequest(Uri.parse('https://soleco-optimizer.ch/Account/SignOut'));
      
      // SOFORT zur Login-WebView wechseln (ohne Warten)
      setState(() {
        _isLoggedIn = false;
        _showLoginWebView = true;
        _isLoggingIn = false;
        _vehicles.clear();
        _sites.clear();
        _currentSite = null;
      });
      
      // Lösche alle lokalen Daten
      await storage.delete(key: _kUser);
      await storage.delete(key: _kPass);
      await storage.delete(key: _kCookieStore);
      await storage.delete(key: _kSelectedSite);
      await _backgroundController.clearCache();
      await _loginController.clearCache();
      
      // Lade Login-Seite in der WebView
      await _loginController.loadRequest(Uri.parse('https://soleco-optimizer.ch/AzureADB2C/Account/SignIn'));
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Abgemeldet')),
        );
      }
    } catch (e) {
      print('Logout error: $e');
      // Fallback: Lokale Abmeldung auch bei Fehler
      await storage.delete(key: _kUser);
      await storage.delete(key: _kPass);
      await storage.delete(key: _kCookieStore);
      await storage.delete(key: _kSelectedSite);
      await _backgroundController.clearCache();
      await _loginController.clearCache();
      
      setState(() {
        _isLoggedIn = false;
        _showLoginWebView = true;
        _isLoggingIn = false;
        _vehicles.clear();
        _sites.clear();
        _currentSite = null;
      });
      
      // Lade Login-Seite auch bei Fehler
      await _loginController.loadRequest(Uri.parse('https://soleco-optimizer.ch/AzureADB2C/Account/SignIn'));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Zeige "Logging in..." Screen wenn Login erfolgreich aber noch Daten laden
    if (_isLoggingIn) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Brand.primary, Brand.primaryDark],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Logging in...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Bitte warten Sie während der Anmeldung',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Zeige Login-WebView wenn Login aktiv ist (ohne AppBar/X-Button)
    if (_showLoginWebView) {
      return Scaffold(
        body: WebViewWidget(controller: _loginController),
      );
    }

    // Zeige Loading-Screen beim App-Start oder während Datenladen
    if (_isLoading) {
      return Scaffold(
        body: Container(
              decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Brand.primary, Brand.primaryDark],
            ),
          ),
          child: Center(
              child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
                children: [
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
                const SizedBox(height: 24),
                Text(
                  _isLoggedIn ? 'Lade Daten...' : 'Melde an...',
                  style: const TextStyle(
          color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!_isLoggedIn) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Bitte warten Sie während der Anmeldung',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ],
            ),
        ),
      ),
    );
  }

    // Zeige Login-WebView wenn nicht eingeloggt (Fallback)
    if (!_isLoggedIn) {
      return Scaffold(
        body: WebViewWidget(controller: _loginController),
      );
    }

    // Zusätzliche Sicherheit: Falls irgendwie die Webseite sichtbar wird
    if (_isLoggedIn && _vehicles.isEmpty && _sites.isEmpty) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Brand.primary, Brand.primaryDark],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Lade Daten...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Bitte warten Sie',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
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
      body: MainScreen(
        sites: _sites,
        currentSite: _currentSite,
        vehicles: _vehicles,
        onSiteChanged: _switchSite,
        onVehicleSelected: _selectVehicle,
        onStartCharging: _startCharging,
        onRefresh: () async {
          setState(() => _isLoading = true);
          await _loadVehicles();
          setState(() => _isLoading = false);
        },
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
