import 'package:flutter/foundation.dart';

import 'package:portlink/app_controller.dart';
import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';

class FakeAppController extends ChangeNotifier implements AppController {
  @override
  bool initialized = true;
  @override
  bool busy = false;
  @override
  List<ServerProfile> profiles = [];
  @override
  String? defaultProfileId;
  @override
  ServerProfile? activeProfile;
  @override
  TunnelStatus tunnelStatus = const TunnelStatus(phase: TunnelPhase.idle);
  @override
  String? errorMessage;
  @override
  String? platformWarning;
  @override
  void reportPlatformWarning(String message) {
    platformWarning = message;
    update();
  }

  @override
  HostTrustRequest? pendingTrust;

  int initializeCalls = 0;
  int disposeCalls = 0;
  int disconnectCalls = 0;
  final connectedIds = <String>[];
  final deletedIds = <String>[];
  final trustAnswers = <bool>[];
  final savedProfiles = <Map<String, Object?>>[];
  String? saveError;
  bool throwOnConnect = false;

  void update() => notifyListeners();

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
    initialized = true;
    update();
  }

  @override
  Future<void> saveProfile({
    String? id,
    required String name,
    required String host,
    required int sshPort,
    required String username,
    String? password,
    required bool makeDefault,
  }) async {
    errorMessage = saveError;
    if (saveError == null) {
      savedProfiles.add({
        'id': id,
        'name': name,
        'host': host,
        'sshPort': sshPort,
        'username': username,
        'password': password,
        'makeDefault': makeDefault,
      });
    }
    update();
  }

  @override
  Future<void> deleteProfile(String id) async {
    deletedIds.add(id);
    profiles = profiles.where((profile) => profile.id != id).toList();
    update();
  }

  @override
  Future<void> setDefault(String id) async {
    defaultProfileId = id;
    update();
  }

  @override
  Future<void> connectProfile(String id) async {
    connectedIds.add(id);
    if (throwOnConnect) throw StateError('secret-that-must-not-appear');
    update();
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    tunnelStatus = const TunnelStatus(phase: TunnelPhase.idle);
    busy = false;
    activeProfile = null;
    pendingTrust = null;
    update();
  }

  @override
  Future<void> shutdown() async {}

  @override
  void answerHostTrust(bool accept) {
    trustAnswers.add(accept);
    pendingTrust = null;
    update();
  }

  @override
  void clearError() {
    errorMessage = null;
    update();
  }

  // Extra non-UI implementation helpers on the real controller are not used.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
