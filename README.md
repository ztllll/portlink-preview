# 端口连 · PortLink

一个极简的 SSH 本地转发工具：保存多个服务器，每台服务器可配置多条端口转发（本地地址:端口 → 服务器可访问的目标地址:端口），选一台连接后所有已启用的转发共用同一条 SSH 会话。默认规则仍是 `127.0.0.1:3080` → 服务器自身 `127.0.0.1:3080`，旧版配置会自动升级为这一条规则。

> Mac统一功能预览版0.1.3：多端口转发、自定义监听/目标地址及逐规则状态与Windows共用实现；原生右键菜单、无Dock/隐藏启动，左键状态图标呼出GUI；保留SSH并发写入修复与22pt红绿菜单栏图标，已通过本机隔离原生大流量验收，最低macOS13，支持Apple Silicon（同时含Intel架构但未实机验）。当前ad-hoc签名、未公证；详见[Mac安装说明](<docs/MAC_PREVIEW.md>)和[验证记录](<docs/VERIFICATION.md>)。Android现有ARM64侧载预览APK（Release优化、debug签名，已通过AOSP模拟器前后台转发及通知停止，物理手机待验）；Windows已有用户在Windows11 x64构建并推送的版本，本次保留其打包修复与单文件启动器；合并后的源码需在Windows重新构建，既有EXE不会自动更新。

## 使用

1. 添加服务器：名称、SSH服务器地址、SSH端口（通常22）、用户名、SSH密码。服务器需已启用SSH，并允许TCP端口转发。
2. 保存配置；首个服务器自动成为默认服务器。密码只进系统安全存储，普通配置不包含密码。
3. 点击连接；首连通过服务器控制台/管理员等另一可信渠道核对完整SHA256主机指纹。拒绝或指纹变化不会继续认证。
4. 在“端口转发”里添加最多32条规则：本地地址（默认 127.0.0.1）、本地端口（1024–65535）、目标地址（默认 127.0.0.1，即服务器自身；也可填服务器能访问的内网地址）、目标端口。通道就绪后访问各规则显示的本地地址。若服务是HTTP，可点击对应规则的“打开”，HTTPS或其他协议请在对应应用中使用。
5. 下次启动自动连接默认服务器。同一时刻只连接一台服务器；不同服务器的规则若使用相同本地端口，切换时先释放旧连接。某条规则的本地端口被占用只会让该条标红，其余规则继续转发，PortLink不会自动换端口，也不会结束占用者。

配置写出使用schemaVersion 2：旧v1配置自动迁移为默认3080规则；保存后旧版本应用不能读取v2，升级前请保留备份，不用旧程序覆盖新配置。多规则功能在Mac和Windows一致；Mac保留22pt红绿状态图、原生右键和无Dock启动，Windows保留绿/红/黄托盘。

### 状态

- **已连接**：SSH已认证、至少一条规则的本地监听建立，且该规则最近一次经SSH的目标TCP探测成功；不代表HTTP/数据库业务认证一定成功。每条规则单独显示“可用 / 远端暂不可用 / 本地端口无法监听”，存在异常规则时整体为“部分可用”。
- **服务未就绪**：SSH与本地监听保留，所有规则的远端目标都无法访问，定期再检查。
- **重连中**：网络暂时故障，使用最多30秒等待的退避策略持续恢复；可以手动停止。
- **连接失败**：认证/主机信任/本地端口占用等阻断性问题，需要处理后手动重试。

macOS使用顶部菜单栏，Windows使用右下角托盘。正常关闭管理窗口只隐藏窗口；托盘“退出并停止转发”或系统退出请求会先清理连接并等待已开始的保存/回滚完成。状态栏不可用时会显示独立警告、窗口不隐藏，关闭窗口会安全退出。桌面通过系统文件锁限制同一数据目录的重复实例；崩溃后锁由系统释放，不依赖删除陈旧PID文件。

Android运行期间通过前台服务保持本次会话，切浏览器可继续使用；通知提供停止按钮。无开机自启动或长期保活承诺。Android13+需允许通知，否则本预览版拒绝建立会话，避免没有可见停止入口。详情见[Android说明](<docs/ANDROID.md>)。

## 开发与运行

建议 Flutter 3.47.x / Dart 3.13.x，实际版本以锁定的依赖和[验证记录](<docs/VERIFICATION.md>)为准。不要使用旧托盘API教程直接升级依赖。

```bash
# 只读诊断，不安装或构建；退出2表示缺少平台前置
dart tool/preflight.dart macos

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

Windows请使用对应venv Python路径和PowerShell环境变量语法。普通测试默认跳过外部Python依赖的集成用例。测试使用隔离的临时本地端口；另有测试验证多规则、单条端口被占用只影响该条、旧配置迁移为3080规则，以及占用者不会被停止。请使用 `--concurrency=1` 避免原生构建资产复制竞态。默认规则运行时需要本机3080空闲。

## 结构

```text
lib/
  app_controller.dart  配置事务、单会话协调、启动连接、指纹确认
  core/                SSH协议适配、转发规则、多端口监听、状态机与重连
  data/                原子配置文件、主机pin、安全凭据接口
  platform/            桌面托盘/窗口、Android会话通道
  ui/                  中文响应式界面
macos/ windows/ android/  各平台构建与原生外壳
test/                  模型/存储/网络/控制器/UI/真实SSH测试
```

配置位于path_provider提供的应用支持目录，普通配置和信任记录分离。保存采用同目录临时文件+flush+rename，维护上一份验证有效的配置备份；安全凭据不进入该备份。最多100个服务器配置。升级保持bundle/application ID不变才能正确沿用系统存储。

本版不含终端、SFTP、云同步、UDP、全局代理、SSH密钥认证、登录系统自启动。

## 发行

- Mac已有ad-hoc签名本机预览ZIP，公开分发仍需Developer ID签名和公证；不能把codesign结构验证当Gatekeeper认可。沙盒Release仅保留所需网络权限。
- Windows需在Windows主机测试构建，正式发行建议签名；未签名可能有SmartScreen警告。
- Android debug APK仅用于自测；正式密钥和商店流程未配置。
- [构建工作流](<.github/workflows/verify.yml>)仅提供CI定义，未上传远端、未实际运行，不能当作CI已通过。

见[构建前诊断](<docs/BUILD_PREFLIGHT.md>)、[Windows构建打包](<docs/WINDOWS.md>)、[两端接续授权与构建](<docs/WINDOWS_ANDROID_NEXT.md>)、[安全边界](<docs/SECURITY.md>)与[验证记录](<docs/VERIFICATION.md>)。
