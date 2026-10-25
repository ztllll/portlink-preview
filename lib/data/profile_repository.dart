import '../core/server_profile.dart';
import 'atomic_json_file.dart';

abstract interface class ProfileRepository {
  Future<ProfileSnapshot> load();
  Future<void> save(ProfileSnapshot snapshot);
}

final class ProfileSnapshot {
  ProfileSnapshot({
    List<ServerProfile> profiles = const [],
    this.defaultProfileId,
  }) : profiles = List.unmodifiable(
         profiles.map((profile) => profile.frozen()),
       );
  final List<ServerProfile> profiles;
  final String? defaultProfileId;

  Map<String, dynamic> toJson() {
    if (profiles.length > 100) throw const FormatException('最多保存 100 个服务器');
    final ids = <String>{};
    for (final profile in profiles) {
      final error = profile.validate();
      if (error != null) throw FormatException(error);
      if (!ids.add(profile.id)) throw const FormatException('服务器标识重复');
    }
    if (defaultProfileId != null && !ids.contains(defaultProfileId)) {
      throw const FormatException('默认服务器不存在');
    }
    return {
      'schemaVersion': 2,
      'profiles': profiles.map((p) => p.toJson()).toList(),
      'defaultProfileId': defaultProfileId,
    };
  }

  factory ProfileSnapshot.fromJson(Map<String, dynamic> json) {
    // v1 profiles have no `rules`; ServerProfile.fromJson upgrades them to the
    // single 127.0.0.1:3080 rule. v2 is written from now on.
    if (json['schemaVersion'] is! int ||
        (json['schemaVersion'] != 1 && json['schemaVersion'] != 2) ||
        json['profiles'] is! List ||
        (json['defaultProfileId'] != null &&
            json['defaultProfileId'] is! String) ||
        json.keys.any(
          (k) => !{'schemaVersion', 'profiles', 'defaultProfileId'}.contains(k),
        )) {
      throw const FormatException('配置版本或格式不受支持');
    }
    final raw = json['profiles'] as List;
    if (raw.length > 100) throw const FormatException('最多保存 100 个服务器');
    final profiles = raw.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('服务器配置格式无效');
      }
      if (json['schemaVersion'] == 2 && !value.containsKey('rules')) {
        throw const FormatException('v2服务器配置缺少转发规则');
      }
      return ServerProfile.fromJson(value);
    }).toList();
    final result = ProfileSnapshot(
      profiles: profiles,
      defaultProfileId: json['defaultProfileId'] as String?,
    );
    result.toJson();
    return result;
  }
}

final class JsonProfileRepository implements ProfileRepository {
  JsonProfileRepository(String filePath) : _file = AtomicJsonFile(filePath);
  final AtomicJsonFile _file;
  @override
  Future<ProfileSnapshot> load() => _file.locked(
    () async => await _file.read(ProfileSnapshot.fromJson) ?? ProfileSnapshot(),
  );
  @override
  Future<void> save(ProfileSnapshot snapshot) => _file.locked(
    () => _file.write(snapshot.toJson(), (json) {
      ProfileSnapshot.fromJson(json);
    }),
  );
}
