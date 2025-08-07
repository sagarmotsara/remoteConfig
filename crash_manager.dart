import 'dart:convert';
import 'dart:developer';
import 'dart:isolate';

import 'package:OmnifulPicker/app/modules/authentication/domain/auth_repository.dart';
import 'package:OmnifulPicker/utils/network/api_handler.dart';
import 'package:OmnifulPicker/utils/network/consts.dart';
import 'package:OmnifulPicker/utils/screen_recording.dart';
import 'package:dio/dio.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:OmnifulPicker/utils/app_update_manager/version_utils.dart';
import 'package:OmnifulPicker/utils/local_storage/shared_preference_utils.dart';
import 'package:flutter_flavor/flutter_flavor.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

class RemoteConfig {
  final bool isMoreData;

  RemoteConfig({required this.isMoreData});

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    return RemoteConfig(
      isMoreData: json['isMoreData'] ?? false,
    );
  }
}

class CrashManager {
  static const String _configUrl =
      'https://raw.githubusercontent.com/sagarmotsara/remoteConfig/refs/heads/main/remoteConfig.json';
  static RemoteConfig? _cachedConfig;
  static bool _isInitialized = false;

  void setUpCrashlytics() async {
    const bool canLogCrashes = !kDebugMode;

    FirebasePerformance.instance.setPerformanceCollectionEnabled(canLogCrashes);

    if (canLogCrashes) {
      // Initialize GitHub Remote Config
      await _initializeRemoteConfig();

      // Handle Crashlytics enabled status when not in Debug,
      // e.g. allow your users to opt-in to crash reporting.
      // Pass all uncaught errors from the framework to Crashlytics.

      FlutterError.onError = (errorDetails) async {
        print('CrashManager: Fatal Error detected - ${errorDetails.exception}');
        if (errorDetails.library == 'image resource service') return;

        // Fatal errors: Send to Firebase based on isMoreData, always send to Slack
        final shouldSendToFirebase = await _shouldSendToFirebase();
        print(
            'CrashManager: Should send fatal error to Firebase: $shouldSendToFirebase');
        if (shouldSendToFirebase) {
          print('CrashManager: Sending fatal error to Firebase Crashlytics');
          await FirebaseCrashlytics.instance.recordFlutterError(errorDetails);
        } else {
          print('CrashManager: Skipping Firebase Crashlytics for fatal error');
        }
        print('CrashManager: Sending fatal error to Slack');
        sendReportToSlack(errorDetails.exception, errorDetails.stack,
            type: "nf");
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        print('CrashManager: Non Fatal Error detected - $error');

        if (error is CameraException &&
            error.code == '404' &&
            error.description == 'No barcode scanner found') {
          print('CrashManager: Ignoring camera exception');
          return true;
        }

        // Check if we should send to Firebase based on Remote Config
        print('CrashManager: Handling non-fatal error');
        _handleNonFatalError(error, stack);
        return true;
      };

      // To catch errors that happen outside of the Flutter context
      Isolate.current.addErrorListener(RawReceivePort((pair) async {
        final List<dynamic> errorAndStacktrace = pair;
        print(
            'CrashManager: Isolate error detected - ${errorAndStacktrace.first}');
        if (pair.first is NetworkImageLoadException) {
          print('CrashManager: Ignoring NetworkImageLoadException');
          return;
        }

        // Fatal errors: Send to Firebase based on isMoreData, always send to Slack
        final shouldSendToFirebase = await _shouldSendToFirebase();
        final shouldSendToSlack = await _shouldSendToSlack();
        print(
            'CrashManager: Should send isolate error to Firebase: $shouldSendToFirebase');
        if (shouldSendToFirebase) {
          print('CrashManager: Sending isolate error to Firebase Crashlytics');
          await FirebaseCrashlytics.instance.recordError(
            errorAndStacktrace.first,
            errorAndStacktrace.last is Stack ? errorAndStacktrace.last : null,
          );
        } else {
          print(
              'CrashManager: Skipping Firebase Crashlytics for isolate error');
        }
        print('CrashManager: Sending isolate error to Slack');
        if (shouldSendToSlack) {
          sendReportToSlack(errorAndStacktrace.first,
              errorAndStacktrace.last is Stack ? errorAndStacktrace.last : null,
              type: "f");
        }
      }).sendPort);
    } else {
      // Force disable Crashlytics collection while doing every day development.
      // Temporarily toggle this to true if you want to test crash reporting in your app.
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    }
  }

  Future<void> _initializeRemoteConfig() async {
    if (_isInitialized) {
      print('CrashManager: Remote config already initialized');
      return;
    }

    try {
      print('CrashManager: Starting GitHub Remote Config initialization...');

      // Fetch config from GitHub using Dio
      final dio = Dio();
      final response = await dio.get(_configUrl);

      if (response.statusCode == 200) {
        final jsonData = response.data;

        // Handle both string and Map responses
        Map<String, dynamic> parsedData;
        if (jsonData is String) {
          // Parse JSON string to Map
          parsedData = Map<String, dynamic>.from(json.decode(jsonData));
        } else if (jsonData is Map<String, dynamic>) {
          // Already a Map
          parsedData = jsonData;
        } else {
          throw FormatException(
              'Unexpected data type: ${jsonData.runtimeType}');
        }

        _cachedConfig = RemoteConfig.fromJson(parsedData);
        _isInitialized = true;

        print('CrashManager: GitHub config fetched successfully');
        print('CrashManager: isMoreData value: ${_cachedConfig!.isMoreData}');

        logEvent(
            'GitHub Remote Config initialized successfully. isMoreData: ${_cachedConfig!.isMoreData}');
      } else {
        print(
            'CrashManager: Failed to fetch config from GitHub. Status: ${response.statusCode}');
        // Set default config if fetch fails
        _cachedConfig = RemoteConfig(isMoreData: false);
        _isInitialized = true;
        logEvent(
            'Failed to fetch GitHub config, using default: isMoreData: false');
      }
    } catch (e) {
      print('CrashManager: Failed to initialize GitHub Remote Config: $e');
      // Set default config if there's an error
      _cachedConfig = RemoteConfig(isMoreData: false);
      _isInitialized = true;
      logEvent(
          'Failed to initialize GitHub Remote Config, using default: isMoreData: false');
    }
  }

  Future<bool> _shouldSendToFirebase() async {
    try {
      print('CrashManager: _shouldSendToFirebase called');

      // Ensure config is initialized
      if (!_isInitialized) {
        await _initializeRemoteConfig();
      }

      final isMoreData = _cachedConfig?.isMoreData ?? false;
      print('CrashManager: Raw isMoreData value: $isMoreData');

      final shouldSendToFirebase = !isMoreData;
      print('CrashManager: Should send to Firebase: $shouldSendToFirebase');

      logEvent(
          'GitHub Remote Config isMoreData: $isMoreData, shouldSendToFirebase: $shouldSendToFirebase');
      return shouldSendToFirebase; // Send to Firebase when isMoreData is false
    } catch (e) {
      print('CrashManager: Error getting GitHub Remote Config isMoreData: $e');
      logEvent('Error getting GitHub Remote Config isMoreData: $e');
      // Default to true (send to Firebase) if there's an error
      return true;
    }
  }

  Future<bool> _shouldSendToSlack() async {
    try {
      print('CrashManager: _shouldSendToSlack called');

      // Ensure config is initialized
      if (!_isInitialized) {
        await _initializeRemoteConfig();
      }

      final isMoreData = _cachedConfig?.isMoreData ?? false;
      print('CrashManager: isMoreData for Slack: $isMoreData');
      logEvent('GitHub Remote Config isMoreData for Slack: $isMoreData');
      return isMoreData; // Always send to Slack
    } catch (e) {
      print(
          'CrashManager: Error getting GitHub Remote Config isMoreData for Slack: $e');
      logEvent('Error getting GitHub Remote Config isMoreData for Slack: $e');
      // Default to true (send to Slack) if there's an error
      return true;
    }
  }

  void _handleNonFatalError(Object error, StackTrace? stack) async {
    try {
      print('CrashManager: _handleNonFatalError called with error: $error');
      final shouldSendToFirebase = await _shouldSendToFirebase();
      final shouldSendToSlack = await _shouldSendToSlack();

      print(
          'CrashManager: Non-fatal error - shouldSendToFirebase: $shouldSendToFirebase, shouldSendToSlack: $shouldSendToSlack');

      if (shouldSendToFirebase) {
        // Send to Firebase
        print('CrashManager: Sending non-fatal error to Firebase Crashlytics');
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
      } else {
        print(
            'CrashManager: Skipping Firebase Crashlytics for non-fatal error');
      }

      if (shouldSendToSlack) {
        // Send to Slack
        if (FlavorConfig.instance.name == BuildVariant.dev.name) {
          try {
            print(
                'CrashManager: Sending non-fatal error to Slack (prod environment)');
            sendReportToSlack(error, stack, type: "nf");
          } catch (e) {
            print('CrashManager: Error sending to Slack: $e');
            logEvent('error in slack : $e');
            // Fallback to Firebase if Slack fails
            FirebaseCrashlytics.instance
                .recordError(error, stack, fatal: false);
          }
        } else {
          // For non-prod environments, still send to Firebase as fallback
          print(
              'CrashManager: Non-prod environment, sending to Firebase as fallback');
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
        }
      }
    } catch (e) {
      print('CrashManager: Error in _handleNonFatalError: $e');
      logEvent('Error in _handleNonFatalError: $e');
      // Fallback to Firebase if there's any error
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
    }
  }

  setUserOnFirebaseCrashlytics() async {
    final VersionUtils versionUtils = await VersionUtils.createInstance();
    final user = await getLoggedInUser();
    if (user != null) {
      await FirebaseCrashlytics.instance.setCustomKey('name', user.name);
      await FirebaseCrashlytics.instance.setCustomKey('user', user.email);
    }

    await FirebaseCrashlytics.instance
        .setCustomKey('workspace', await getSavedSubDomain());
    await FirebaseCrashlytics.instance
        .setCustomKey('buildNo', versionUtils.buildNumber);
    final deviceId = await AuthRepository().getDeviceId();
    await FirebaseCrashlytics.instance.setCustomKey('deviceId', '$deviceId');
  }

  logScreen(String name) => logEvent('Navigating to $name');

  logEvent(String message) {
    log(message);
    FirebaseCrashlytics.instance.log(message);
    ApiHandler().cacheInterceptor.cache('EventLogger: $message');
  }
}
