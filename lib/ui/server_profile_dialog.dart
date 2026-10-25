import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/forward_rule.dart';
import '../core/server_profile.dart';
import 'forward_rules_editor.dart';

class ServerProfileDialog extends StatefulWidget {
  const ServerProfileDialog({
    super.key,
    required this.controller,
    this.profile,
  });

  final AppController controller;
  final ServerProfile? profile;

  @override
  State<ServerProfileDialog> createState() => _ServerProfileDialogState();
}

class _ServerProfileDialogState extends State<ServerProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _rulesKey = GlobalKey<ForwardRulesEditorState>();
  late bool _makeDefault;
  bool _obscurePassword = true;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _name = TextEditingController(text: profile?.name ?? '');
    _host = TextEditingController(text: profile?.host ?? '');
    _port = TextEditingController(text: (profile?.sshPort ?? 22).toString());
    _username = TextEditingController(text: profile?.username ?? '');
    _makeDefault =
        widget.controller.profiles.isEmpty ||
        (profile != null && widget.controller.defaultProfileId == profile.id);
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || widget.controller.busy || !widget.controller.initialized) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final rules = _rulesKey.currentState?.collect();
    if (rules == null) {
      setState(() => _error = '请检查转发端口是否填写完整');
      return;
    }
    final draft = ServerProfile(
      id: widget.profile?.id ?? 'draft',
      name: _name.text.trim(),
      host: _host.text.trim(),
      sshPort: int.parse(_port.text.trim()),
      username: _username.text.trim(),
      rules: rules,
    );
    final validation = draft.validate();
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      widget.controller.clearError();
      await widget.controller.saveProfile(
        id: widget.profile?.id,
        name: draft.name,
        host: draft.host,
        sshPort: draft.sshPort,
        username: draft.username,
        password: _password.text.isEmpty ? null : _password.text,
        makeDefault: _makeDefault,
        rules: draft.rules,
      );
      if (!mounted) return;
      if (widget.controller.errorMessage != null) {
        setState(() {
          _error = widget.controller.errorMessage;
          _saving = false;
        });
        return;
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = widget.controller.errorMessage ?? '保存失败，请检查系统凭据存储是否可用后重试。';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final disabled =
              _saving ||
              widget.controller.busy ||
              !widget.controller.initialized;
          return AlertDialog(
            scrollable: true,
            title: Text(_editing ? '编辑服务器' : '添加服务器'),
            content: SizedBox(
              width: 460,
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '通过 SSH 安全连接，并把本机端口转发到服务器可访问的端口。',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 22),
                      TextFormField(
                        key: const ValueKey('profile-name'),
                        controller: _name,
                        autofocus: true,
                        enabled: !disabled,
                        maxLength: 100,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '显示名称',
                          hintText: '例如：工作服务器',
                          counterText: '',
                        ),
                        validator: (value) =>
                            (value?.trim().isEmpty ?? true) ? '请输入服务器名称' : null,
                      ),
                      const SizedBox(height: 16),
                      Builder(
                        builder: (context) {
                          final hostField = TextFormField(
                            key: const ValueKey('profile-host'),
                            controller: _host,
                            enabled: !disabled,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(
                              labelText: '主机地址',
                              hintText: 'IP 或域名，不含协议前缀',
                            ),
                            validator: (value) =>
                                (value?.trim().isEmpty ?? true)
                                ? '请输入主机地址'
                                : null,
                          );
                          final portField = TextFormField(
                            key: const ValueKey('profile-port'),
                            controller: _port,
                            enabled: !disabled,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'SSH 端口',
                            ),
                            validator: (value) {
                              final port = int.tryParse(value?.trim() ?? '');
                              return port == null || port < 1 || port > 65535
                                  ? '端口应为 1–65535'
                                  : null;
                            },
                          );
                          if (MediaQuery.of(context).size.width < 470) {
                            return Column(
                              children: [
                                hostField,
                                const SizedBox(height: 16),
                                portField,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: hostField),
                              const SizedBox(width: 12),
                              SizedBox(width: 116, child: portField),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('profile-username'),
                        controller: _username,
                        enabled: !disabled,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(labelText: 'SSH 用户名'),
                        validator: (value) => (value?.trim().isEmpty ?? true)
                            ? '请输入 SSH 用户名'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('profile-password'),
                        controller: _password,
                        enabled: !disabled,
                        obscureText: _obscurePassword,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _save(),
                        decoration: InputDecoration(
                          labelText: _editing ? '新密码（留空保留原密码）' : 'SSH 密码',
                          helperText: '仅保存在系统安全凭据存储中',
                          helperMaxLines: 2,
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                            onPressed: disabled
                                ? null
                                : () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (value) =>
                            !_editing && (value?.isEmpty ?? true)
                            ? '请输入 SSH 密码'
                            : null,
                      ),
                      const SizedBox(height: 20),
                      ForwardRulesEditor(
                        key: _rulesKey,
                        initial:
                            widget.profile?.rules ??
                            const [ForwardRule.legacy()],
                        enabled: !disabled,
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: _makeDefault,
                        onChanged: disabled
                            ? null
                            : (value) =>
                                  setState(() => _makeDefault = value ?? false),
                        title: const Text('设为默认服务器'),
                        subtitle: const Text('下次启动时自动连接；不会立即切换当前连接。'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      if (widget.profile != null &&
                          widget.profile!.id ==
                              widget.controller.activeProfile?.id)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('正在使用此服务器：保存成功后将重新连接。'),
                        ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: disabled ? null : _save,
                child: Text(_saving ? '正在保存…' : '保存服务器'),
              ),
            ],
          );
        },
      ),
    );
  }
}
