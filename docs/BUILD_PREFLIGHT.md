# 构建前诊断与平台前置

在项目根目录运行，不安装软件、不下载组件、不修改系统设置、不读SSH密码、不关闭端口占用者：

```bash
dart tool/preflight.dart macos
dart tool/preflight.dart android --json
dart tool/preflight.dart windows
```

本地工程内准备的SDK可用 `../.tools/flutter/bin/cache/dart-sdk/bin/dart` 代替dart；独立源码包不包含该SDK。命令从自身位置定位项目，从FLUTTER_ROOT、运行它的SDK位置或PATH定位Flutter。

退出码：0=未发现阻断性前置缺失，2=明确缺条件，1=诊断失败，64=参数错误。**0也不是原生编译或实机验收通过**。它只查看文件和执行有限的版本探测；不会执行flutter build、sdkmanager安装或接受许可证。

## Mac

- 完整Xcode而非Command Line Tools；完成首次启动、所需组件和许可证。Flutter3.47/Dart3.13为本版最低要求。
- 工程已引用Flutter生成的Swift Package，插件都支持该路径；Xcode可用后正常flutter pub get/prepare会生成依赖。不要手改或提交ephemeral生成包。若关闭SPM，则需CocoaPods。
- 本工具不需要跨应用Keychain Sharing，明确使用系统登录Keychain（MacOsOptions usesDataProtectionKeychain=false）并移除共享组权限。这仍是OS凭据库，没有文件明文回退；已签名应用上的真实保存/重启读取仍待验证。
- 若用旧预览曾写入Data Protection Keychain，新存储位置不会静默迁移，需在应用编辑服务器重新保存密码。
- Mac工程PRODUCT_NAME、产品引用、scheme和RunnerTests TEST_HOST已统一PortLink大小写；避免大小写敏感卷上测试宿主失效。

## Windows

- 必须Windows主机。Visual Studio C++桌面工作负载、ATL组件及相应SDK/CMake；仅Flutter doctor通过不能证明ATL存在，锁定安全存储插件直接包含atlstr.h。
- 已锁定jni1.1.0在Windows找到JNI时使用TARGET_NAME设置delay-load属性，应用在生成插件include的范围内设置兼容值jni，include后立即unset，不改pub cache/生成文件。此条件性兼容措施仍待Windows CMake真正配置和链接验证；Windows不因此强制需要JDK。
- Windows产物要保留整个Release目录，包含Flutter DLL、原生资产和插件；不能只发exe。

## Android

- JDK17+、SDK36平台、build-tools、NDK28.2.13676358（包括clang、llvm-ar、ld.lld）、CMake3.22.1。只有adb/platform-tools或java启动器不够。
- 诊断可检查这些路径和sdkmanager/许可证目录，但不会替用户接受条款。SDK目录可能随安装方式不同，应以真实构建验证。
- 当前依赖含cnativeapi和JNI原生构建，哪怕运行时不启桌面托盘，也不能假定Android无需NDK。
- CI已显式配置Android组件安装及构建前检查；它只是源码定义，尚未在远端实际运行。

## 端口占用

诊断只尝试独占绑定127.0.0.1:3080并立即关闭，不连接现有服务。被占用时是warning：不阻止编译，但正式运行无法建立本地转发。本机Tabby已占该端口，没有擅自停止。

## 本机实际结果

2026-10-23历史三目标诊断退出2；2026-10-24用户安装完整Xcode27.1后Mac检查已退出0，并完成发布应用构建与本机隔离原生验收。Android仍缺JDK/完整SDK/NDK/CMake；Windows仍缺Windows主机。SDK版本显示本地预发布元数据，工具额外警告不可当作官方正式发行证明。完整JSON证据随验证目录提供，不含服务器凭据。
