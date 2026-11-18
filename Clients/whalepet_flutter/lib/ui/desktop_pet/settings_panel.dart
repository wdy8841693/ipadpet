import 'package:flutter/material.dart';

import '../../core/config/app_settings.dart';
import '../pet_ui_model.dart';
import 'pet_theme.dart';

/// 设置面板：服务器地址、令牌、播报与窗口开关。
///
/// 桌面端没有菜单栏，所以设置直接是窗口里的一块面板（和聊天面板同尺寸）。
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.runtime,
    required this.onClose,
    required this.onOpenChat,
    this.desktopOptions = true,
  });

  /// 是否显示只有桌面窗口才有的开关（置顶 / 透明穿透）。
  /// Android 全屏场景传 false。
  final bool desktopOptions;

  final PetViewModel runtime;
  final VoidCallback onClose;
  final VoidCallback onOpenChat;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final TextEditingController _serverController;
  final TextEditingController _tokenController = TextEditingController();
  late final TextEditingController _wakePhraseController;
  late final TextEditingController _wakeAliasController;
  late final TextEditingController _wakeAckController;
  late bool _voiceWake;
  late bool _announcements;
  late bool _speak;
  late bool _alwaysOnTop;
  late bool _autostart;
  late bool _oneShotCommand;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final AppSettings settings = widget.runtime.settings;
    _serverController = TextEditingController(text: settings.serverUrl);
    _wakePhraseController = TextEditingController(text: settings.wakePhrase);
    _wakeAliasController =
        TextEditingController(text: settings.wakeAliases.join('，'));
    _wakeAckController = TextEditingController(text: settings.wakeAck);
    _voiceWake = settings.voiceWakeEnabled;
    _announcements = settings.subscriptionsAnnouncements;
    _speak = settings.speakResponses;
    _alwaysOnTop = settings.alwaysOnTop;
    _autostart = settings.autostartEnabled;
    _oneShotCommand = settings.oneShotCommandEnabled;
  }

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    _wakePhraseController.dispose();
    _wakeAliasController.dispose();
    _wakeAckController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    final AppSettings next = widget.runtime.settings.copyWith(
      serverUrl: _serverController.text.trim(),
      subscriptionsAnnouncements: _announcements,
      speakResponses: _speak,
      alwaysOnTop: _alwaysOnTop,
      voiceWakeEnabled: _voiceWake,
      wakePhrase: _wakePhraseController.text.trim().isEmpty
          ? '小鲸小鲸'
          : _wakePhraseController.text.trim(),
      wakeAliases: _wakeAliasController.text
          .split(RegExp(r'[,，;；\s]+'))
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false),
      wakeAck: _wakeAckController.text.trim(),
      autostartEnabled: _autostart,
      oneShotCommandEnabled: _oneShotCommand,
    );
    final String token = _tokenController.text.trim();
    await widget.runtime.applySettings(next, token: token.isEmpty ? null : token);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _message = next.parsedServerUri == null
          ? '地址格式不对，应该像 http://192.168.1.10:8787'
          : '已保存，正在重连…';
    });
    _tokenController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final PetViewModel runtime = widget.runtime;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: Text('设置', style: kPanelTitleStyle)),
              IconButton(
                tooltip: '聊天',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                color: const Color(0xFF9FD8F0),
                onPressed: widget.onOpenChat,
                icon: const Icon(Icons.chat_bubble_outline),
              ),
              IconButton(
                tooltip: '关闭',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                color: const Color(0xFF9FD8F0),
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 4),
                  const Text('服务器地址', style: kPanelLabelStyle),
                  const SizedBox(height: 4),
                  _Field(
                    controller: _serverController,
                    hint: 'http://<运行 DSH 的机器 IP>:8787',
                  ),
                  const SizedBox(height: 10),
                  const Text('访问令牌（留空则不修改）', style: kPanelLabelStyle),
                  const SizedBox(height: 4),
                  _Field(
                    controller: _tokenController,
                    hint: '粘贴 ~/.dsh/whalepet/ipad-token 的内容',
                    obscure: true,
                  ),
                  const SizedBox(height: 6),
                  _SwitchRow(
                    label: '语音播报回答',
                    value: _speak,
                    onChanged: (bool value) => setState(() => _speak = value),
                  ),
                  _SwitchRow(
                    label: '播报其它会话的任务',
                    value: _announcements,
                    onChanged: (bool value) =>
                        setState(() => _announcements = value),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.desktopOptions
                        ? '本地语音（离线 KWS + 听写）'
                        : '本地语音（系统识别 + 唤醒词匹配）',
                    style: kPanelLabelStyle,
                  ),
                  _SwitchRow(
                    label: '开启唤醒词常驻侦听',
                    value: _voiceWake,
                    onChanged: (bool value) => setState(() => _voiceWake = value),
                  ),
                  if (widget.desktopOptions)
                    _SwitchRow(
                      label: '一句话带命令（唤醒词后直接说指令）',
                      value: _oneShotCommand,
                      onChanged: (bool value) =>
                          setState(() => _oneShotCommand = value),
                    ),
                  const Text('唤醒词 / 别名（逗号分隔）/ 应答', style: kPanelLabelStyle),
                  const SizedBox(height: 4),
                  _Field(controller: _wakePhraseController, hint: '小鲸小鲸'),
                  const SizedBox(height: 5),
                  _Field(controller: _wakeAliasController, hint: '小金小金，小京小京'),
                  const SizedBox(height: 5),
                  _Field(controller: _wakeAckController, hint: '我在（留空则不播应答）'),
                  const SizedBox(height: 6),
                  if (widget.desktopOptions) ...<Widget>[
                    _SwitchRow(
                      label: '窗口置顶',
                      value: _alwaysOnTop,
                      onChanged: (bool value) =>
                          setState(() => _alwaysOnTop = value),
                    ),
                    if (runtime.autostartSupported)
                      _SwitchRow(
                        label: '开机自动启动',
                        value: _autostart,
                        onChanged: (bool value) =>
                            setState(() => _autostart = value),
                      ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '客户端 ID：${runtime.runtimeClientId}',
                    style: kPanelLabelStyle,
                  ),
                  Text(
                    '状态：${runtime.connectionLabel}'
                    '${runtime.speechAvailable ? ' · 播报就绪' : ' · 播报不可用'}',
                    style: kPanelLabelStyle,
                  ),
                  Text(
                    '语音：${runtime.voiceStateLabel}',
                    style: kPanelLabelStyle,
                  ),
                  if (runtime.lastError != null) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      runtime.lastError!,
                      style: const TextStyle(
                        color: Color(0xFFFFB4A0),
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      _message!,
                      style: const TextStyle(
                        color: Color(0xFF9FE8C8),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : _save,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF7FE3FF),
                    side: const BorderSide(color: Color(0x6648D6F5)),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(_saving ? '保存中…' : '保存并重连'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: runtime.reconnect,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF9FD8F0),
                  side: const BorderSide(color: Color(0x3348D6F5)),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('重连'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: kPanelValueStyle,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0x66CFEFFF), fontSize: 11),
        filled: true,
        fillColor: const Color(0x33102A45),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Color(0x3348D6F5)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Color(0x3348D6F5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Color(0x8848D6F5)),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 27,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xCCEAF9FF), fontSize: 12),
            ),
          ),
          Transform.scale(
            scale: 0.72,
            child: Switch(
              value: value,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
