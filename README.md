# 端口连 · PortLink

一个极简的 SSH 本地转发工具：保存多个服务器，选一台连接，将远端服务器自身 `127.0.0.1:3080` 映射到当前设备的 `127.0.0.1:3080`。

> 开发预览版 0.1.0。源码已实现，测试与平台构建的实际结果见[验证记录](<docs/VERIFICATION.md>)；未验证的平台不等于已正式支持。

## 使用

1. 添加服务器：名称、SSH服务器地址、SSH端口（通常22）、用户名、SSH密码。服务器需已启用SSH，并允许TCP端口转发。
2. 保存配置；首个服务器自动成为默认服务器。密码只进系统安全存储，普通配置不包含密码。
3. 点击连接；首连通过服务器控制台/管理员等另一可信渠道核对完整SHA256主机指纹。拒绝或指纹变化不会继续认证。
4. 显示通道就绪后访问 `127.0.0.1:3080`。若服务是HTTP，可点击“打开HTTP页面”，HTTPS或其他协议请在对应应用中使用。
5. 下次启动自动连接默认服务器。多个配置不能同时占用本机3080，切换时先释放旧连接。

### 状态

- **已连接**：SSH已认证、本地监听建立，且最近一次经SSH的目标TCP探测成功；不代表HTTP/数据库业务认证一定成功。
- **服务未就绪**：SSH与本地监听保留，远端3080无法访问，定期再检查。
- **重连中**：网络暂时故障，使用最多30秒等待的退避策略持续恢复；可以手动停止。
- **连接失败**：认证/主机信任/本地端口占用等阻断性问题，需要处理后手动重试。

macOS使用顶部菜单栏，Windows使用右下角托盘。关闭管理窗口只隐藏窗口；从托盘选择“退出并停止转发”才退出。状态栏不可用时不隐藏窗口。

Android运行期间通过前台服务保持本次会话，切浏览器可继续使用；通知提供停止按钮。无开机自启动或长期保活承诺。Android13+需允许通知，否则本预览版拒绝建立会话，避免没有可见停止入口。详情见[Android说明](<docs/ANDROID.md>)。

## 开发与运行

建议 Flutter 3.47.x / Dart 3.13.x，实际版本以锁定的依赖和[验证记录](<docs/VERIFICATION.md>)为准。不要使用旧托盘API教程直接升级依赖。

```bash
flutter pub get
flutter analyze
flutter test --concurrency=1

# Mac（需要完整Xcode、对应开发组件及插件所需工具）
flutter run -d macos
flutter build macos --release

# Windows（在Windows主机，需Visual Studio C++桌面工具链）
flutter run -d windows
flutter build windows --release

# Android（需Android SDK/JDK和设备）
flutter run -d <device-id>
flutter build apk --debug
```

真实SSH集成测试只使用临时随机主机密钥和测试账号，不需要真实服务器：

```bash
python3 -m venv .venv-ssh-test
.venv-ssh-test/bin/python -m pip install asyncssh==2.24.1
PORTLINK_SSH_TEST_PYTHON="$PWD/.venv-ssh-test/bin/python" \
  flutter test test/ssh_integration_test.dart --concurrency=1
```

Windows请使用对应venv Python路径和PowerShell环境变量语法。普通测试默认跳过外部Python依赖的集成用例。数据传输测试使用隔离的临时本地端口，SSH目标仍固定3080；另有测试验证正式构造固定3080及占用报错，不会停止占用者。请使用 `--concurrency=1` 避免原生构建资产复制竞态。正式应用运行仍需要本机3080空闲。

## 结构

```text
lib/
  app_controller.dart  配置事务、单会话协调、启动连接、指纹确认
  core/                SSH协议适配、3080监听、状态机与重连
  data/                原子配置文件、主机pin、安全凭据接口
  platform/            桌面托盘/窗口、Android会话通道
  ui/                  中文响应式界面
macos/ windows/ android/  各平台构建与原生外壳
test/                  模型/存储/网络/控制器/UI/真实SSH测试
```

配置位于path_provider提供的应用支持目录，普通配置和信任记录分离。保存采用同目录临时文件+flush+rename，维护上一份验证有效的配置备份；安全凭据不进入该备份。最多100个服务器配置。升级保持bundle/application ID不变才能正确沿用系统存储。

本版不含终端、SFTP、云同步、UDP、全局代理、SSH密钥认证、登录系统自启动。

## 发行

- Mac公开分发需Developer ID签名和公证。本地未签名预览不能当作正式发行包。沙盒Release已声明出站网络与本地监听权限。
- Windows需在Windows主机测试构建，正式发行建议签名；未签名可能有SmartScreen警告。
- Android debug APK仅用于自测；正式密钥和商店流程未配置。
- [构建工作流](<.github/workflows/verify.yml>)仅提供CI定义，未上传远端、未实际运行，不能当作CI已通过。

见[安全边界](<docs/SECURITY.md>)与[验证记录](<docs/VERIFICATION.md>)。
