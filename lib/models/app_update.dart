/// Metadata published alongside the APK. Build numbers are the canonical
/// pubspec build numbers; Android split APK version codes are separate.
class InstalledAppInfo {
  const InstalledAppInfo({
    required this.versionName,
    required this.versionCode,
    required this.buildNumber,
    required this.packageName,
    required this.abis,
    this.sdkInt = 24,
  });

  factory InstalledAppInfo.fromJson(Map<String, dynamic> json) =>
      InstalledAppInfo(
        versionName: json['versionName'] as String,
        versionCode: (json['versionCode'] as num).toInt(),
        buildNumber: (json['buildNumber'] as num).toInt(),
        packageName: json['packageName'] as String,
        abis: List<String>.from(json['abis'] as List),
        sdkInt: (json['sdkInt'] as num).toInt(),
      );

  final String versionName;
  final int versionCode;
  final int buildNumber;
  final String packageName;
  final List<String> abis;
  final int sdkInt;
}

class UpdateArtifact {
  const UpdateArtifact({
    required this.abi,
    required this.url,
    required this.size,
    required this.sha256,
    required this.versionCode,
  });

  factory UpdateArtifact.fromJson(String abi, Map<String, dynamic> json) {
    final uri = Uri.parse(json['url'] as String);
    final size = json['size'];
    final code = json['versionCode'];
    final hash = json['sha256'] as String;
    if (!const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(abi) ||
        !isSecureUpdateUri(uri) ||
        size is! int ||
        size <= 0 ||
        size > 600 * 1024 * 1024 ||
        code is! int ||
        code <= 0 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid APK update metadata');
    }
    return UpdateArtifact(
      abi: abi,
      url: uri,
      size: size,
      sha256: hash.toLowerCase(),
      versionCode: code,
    );
  }

  final String abi;
  final Uri url;
  final int size;
  final String sha256;
  final int versionCode;
}

class UpdateRelease {
  const UpdateRelease({
    required this.versionName,
    required this.buildNumber,
    required this.releaseNotes,
    required this.architectures,
    this.packageName = 'com.example.english_point_reading',
    this.minSdk = 24,
    this.certSha256 =
        'be287a9d0e703355421be11adf674ead5a9dee6ff6288404421ab08b7ef26aa5',
  });

  factory UpdateRelease.fromJson(Map<String, dynamic> json) {
    final version = json['versionName'];
    final build = json['buildNumber'];
    final notes = json['releaseNotes'];
    final rawArtifacts = json['architectures'];
    final packageName = json['packageName'];
    final minSdk = json['minSdk'];
    final cert = json['certSha256'];
    if (json['schemaVersion'] != 1 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$').hasMatch(version) ||
        build is! int ||
        build <= 0 ||
        notes is! String ||
        packageName is! String ||
        packageName.isEmpty ||
        minSdk is! int ||
        minSdk < 24 ||
        cert is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(cert) ||
        rawArtifacts is! Map ||
        rawArtifacts.isEmpty) {
      throw const FormatException('Invalid update manifest');
    }
    final artifacts = <String, UpdateArtifact>{};
    for (final entry in rawArtifacts.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid update architecture');
      }
      artifacts[entry.key as String] = UpdateArtifact.fromJson(
        entry.key as String,
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
    return UpdateRelease(
      versionName: version,
      buildNumber: build,
      releaseNotes: notes,
      architectures: Map.unmodifiable(artifacts),
      packageName: packageName,
      minSdk: minSdk,
      certSha256: cert.toLowerCase(),
    );
  }

  final String versionName;
  final int buildNumber;
  final String releaseNotes;
  final Map<String, UpdateArtifact> architectures;
  final String packageName;
  final int minSdk;
  final String certSha256;

  UpdateArtifact? artifactFor(InstalledAppInfo installed) {
    for (final abi in installed.abis) {
      final artifact = architectures[abi];
      if (artifact != null) return artifact;
    }
    return null;
  }

  bool isNewerThan(InstalledAppInfo installed) {
    final artifact = artifactFor(installed);
    return buildNumber > installed.buildNumber &&
        packageName == installed.packageName &&
        minSdk <= installed.sdkInt &&
        artifact != null &&
        artifact.versionCode > installed.versionCode;
  }
}

bool isSecureUpdateUri(Uri uri) =>
    uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
