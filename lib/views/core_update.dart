import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class CoreUpdateView extends StatefulWidget {
  const CoreUpdateView({super.key});

  @override
  State<CoreUpdateView> createState() => _CoreUpdateViewState();
}

class _CoreRelease {
  const _CoreRelease({
    required this.tag,
    required this.name,
    required this.assetName,
    required this.downloadUrl,
    required this.size,
    required this.updatedAt,
  });

  final String tag;
  final String name;
  final String assetName;
  final String downloadUrl;
  final int size;
  final DateTime? updatedAt;
}

class _CoreUpdateViewState extends State<CoreUpdateView> {
  static const _releaseApi =
      'https://api.github.com/repos/zpvel/FlClash/releases/tags/smart-alpha-core';
  static const _requiredSymbols = [
    'invokeAction',
    'startTUN',
    'quickSetup',
    'setEventListener',
    'getTraffic',
    'stopTun',
  ];

  Map<String, dynamic> _info = {};
  _CoreRelease? _release;
  String? _status;
  double? _progress;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final info = await app?.getCoreUpdateInfo() ?? {};
    _CoreRelease? release;
    Object? error;
    try {
      release = await _fetchLatestRelease();
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() {
      _info = info;
      _release = release;
      _status = error == null ? null : '远程版本读取失败：$error';
    });
  }

  Future<void> _checkAndUpdate() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _progress = null;
      _status = '正在检测远程核心...';
    });
    try {
      final release = await _fetchLatestRelease();
      if (!mounted) return;
      setState(() {
        _release = release;
        _status = '正在下载 ${release.assetName}...';
      });
      final ok = await _downloadAndInstall(release);
      if (!mounted) return;
      setState(() {
        _status = ok ? '更新成功，完全重启 App 后生效。' : '更新失败。';
      });
      globalState.showMessage(
        title: ok ? '核心更新' : '核心更新失败',
        message: TextSpan(text: _status),
        cancelable: false,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.toString();
      });
      globalState.showMessage(
        title: '核心更新失败',
        message: TextSpan(text: e.toString()),
        cancelable: false,
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _progress = null;
        });
      }
    }
  }

  Future<_CoreRelease> _fetchLatestRelease() async {
    final dio = Dio();
    final response = await dio.get(
      _releaseApi,
      options: Options(
        headers: {'User-Agent': browserUa},
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    final assets = (data['assets'] as List? ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final asset = assets.cast<Map<String, dynamic>?>().firstWhere((item) {
      final name = item?['name']?.toString().toLowerCase() ?? '';
      return name.contains('android-arm64-v8a') &&
          name.contains('libclash') &&
          (name.endsWith('.zip') || name.endsWith('.so'));
    }, orElse: () => null);
    if (asset == null) {
      throw '没有找到 android-arm64-v8a 专用 libclash.so 资产。';
    }
    return _CoreRelease(
      tag: data['tag_name']?.toString() ?? '',
      name: data['name']?.toString() ?? '',
      assetName: asset['name']?.toString() ?? '',
      downloadUrl: asset['browser_download_url']?.toString() ?? '',
      size: (asset['size'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(asset['updated_at']?.toString() ?? ''),
    );
  }

  Future<bool> _downloadAndInstall(_CoreRelease release) async {
    if (release.downloadUrl.isEmpty) {
      throw '远程核心下载地址为空。';
    }
    final tempPath = p.join(await appPath.tempPath, 'core-${utils.id}.bin');
    final targetPath = p.join(
      await appPath.tempPath,
      'libclash-${utils.id}.so',
    );
    final dio = Dio();
    await dio.download(
      release.downloadUrl,
      tempPath,
      onReceiveProgress: (count, total) {
        if (!mounted || total <= 0) return;
        setState(() {
          _progress = count / total;
        });
      },
      options: Options(
        headers: {'User-Agent': browserUa},
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    final source = File(tempPath);
    final bytes = await source.readAsBytes();
    final coreBytes = _extractCoreBytes(release.assetName, bytes);
    final target = File(targetPath);
    await target.writeAsBytes(coreBytes, flush: true);
    try {
      return await app?.installCoreOverride(targetPath) ?? false;
    } finally {
      await source.safeDelete();
      await target.safeDelete();
    }
  }

  Uint8List _extractCoreBytes(String name, Uint8List bytes) {
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final entry = archive.files.firstWhere(
        (item) =>
            item.name == 'lib/arm64-v8a/libclash.so' ||
            p.basename(item.name) == 'libclash.so',
        orElse: () => throw '压缩包内没有找到 libclash.so',
      );
      return _validateFlClashCore(Uint8List.fromList(entry.content));
    }
    return _validateFlClashCore(bytes);
  }

  Uint8List _validateFlClashCore(Uint8List bytes) {
    if (bytes.length < 4 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46) {
      throw '不是有效的 ELF 核心文件。';
    }
    final missing = _requiredSymbols
        .where((symbol) => !_containsBytes(bytes, symbol.codeUnits))
        .toList();
    if (missing.isNotEmpty) {
      throw '这个核心不是 FlClash 专用 libclash.so，缺少 ${missing.first}。';
    }
    return bytes;
  }

  bool _containsBytes(Uint8List source, List<int> pattern) {
    if (pattern.isEmpty || pattern.length > source.length) return false;
    for (var i = 0; i <= source.length - pattern.length; i++) {
      var matched = true;
      for (var j = 0; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }

  Future<bool> _clearOverride() async {
    return await app?.clearCoreOverride() ?? false;
  }

  Future<void> _restoreBuiltIn() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final ok = await _clearOverride();
      if (!mounted) return;
      setState(() {
        _status = ok ? '已恢复 APK 内置核心，重启后生效。' : '恢复失败。';
      });
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = _info['installed'] == true;
    final size = (_info['size'] as num?)?.toInt() ?? 0;
    final lastModified = (_info['lastModified'] as num?)?.toInt() ?? 0;
    return CommonScaffold(
      title: 'Alpha 核心更新',
      isLoading: _loading,
      actions: [
        IconButton(
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前核心', style: context.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(installed ? '已安装覆盖核心' : '使用 APK 内置核心'),
                  if (installed) ...[
                    Text('大小：${_formatBytes(size)}'),
                    if (lastModified > 0)
                      Text(
                        '安装时间：${DateTime.fromMillisecondsSinceEpoch(lastModified).showFull}',
                      ),
                  ],
                  const SizedBox(height: 12),
                  Text('远程版本', style: context.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_release?.tag ?? '未检测'),
                  if ((_release?.assetName ?? '').isNotEmpty)
                    Text(_release!.assetName),
                  if ((_release?.size ?? 0) > 0)
                    Text('远程大小：${_formatBytes(_release!.size)}'),
                  if (_release?.updatedAt != null)
                    Text('更新时间：${_release!.updatedAt!.toLocal().showFull}'),
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    Text(_status!),
                  ],
                ],
              ),
            ),
          ),
          if (_progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : _checkAndUpdate,
            icon: const Icon(Icons.system_update_alt),
            label: const Text('检查并更新'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _loading || !installed ? null : _restoreBuiltIn,
            icon: const Icon(Icons.restore),
            label: const Text('恢复 APK 内置核心'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _loading ? null : () => appController.handleExit(),
            icon: const Icon(Icons.power_settings_new),
            label: const Text('退出 App'),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
  }
}
