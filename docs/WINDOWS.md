# Windows 构建、便携打包与验收

## 当前状态

截至 2026-10-24，实施主机是 macOS，未发现运行中的 Windows VM；**尚无 Windows 原生编译、PowerShell 执行或桌面验收结果**。本次提供脚本、缓存源码核对与合成 PE 测试，不能写成“Windows EXE 已构建”。不创建或上传远端仓库，不自动安装工具，不更改签名、执行策略、防火墙或系统安全设置。

生产固定监听 127.0.0.1:3080，SSH 目标也是服务器 127.0.0.1:3080。端口被占时安全失败，不自动换端口、不连接未知已有服务、不终止占用者。

## Windows 前置

- Windows 10/11 x64 或 ARM64；Flutter **3.47+**、Dart **3.13+** 的已准备 Windows SDK。
- Visual Studio / Build Tools 的 Desktop development with C++、匹配架构 MSVC、CMake、Windows 10/11 SDK。
- **匹配 toolset 与架构的 C++ ATL**。脚本实际检查 atlmfc/include/atlstr.h 与 atlmfc/lib/架构/atls.lib，不能只确认 C++ workload。
- VS 自带的 Release VC CRT 再分发目录。打包从 VC/Redist/MSVC/版本/架构/Microsoft.VC*.CRT 复制，不从 System32 搜集 DLL、不使用 Debug CRT，操作者须遵守 Microsoft 再分发许可。
- 锁定依赖已解析。首次 Windows checkout 不可复用含 macOS 绝对路径的 package config，需在 Windows 显式 pub get --enforce-lockfile。

脚本不安装工具。Flutter build 仍可能获取缺失 engine 资产，需要网络时须由操作者明确允许。Flutter 3.47 Windows command 根据主机架构选目标，脚本要求 Architecture 与 Windows OSArchitecture 一致，不假装跨架构构建。

## 可执行流程

在项目根目录、普通 Windows PowerShell 5.1 或 PowerShell 7 会话执行。无需管理员权限。若组织策略禁止脚本，先由管理员/发行者审核签署；不要降低执行策略或绕过 SmartScreen。

~~~powershell
# 仅使用PowerShell parser检查语法，不构建、不启动应用。
.\tool\windows\check_syntax.ps1

# 初次准备锁定依赖、串行测试，然后构建正常lib/main.dart Release。
.\tool\windows\build.ps1 -FlutterRoot C:\sdk\flutter -Architecture x64 -ResolveDependencies -RunTests

# 依赖已准备时可省略两个开关。
.\tool\windows\build.ps1 -FlutterRoot C:\sdk\flutter -Architecture x64

# 完整Release树 + Release CRT；创建并重新展开核对ZIP。
.\tool\windows\package.ps1 -FlutterRoot C:\sdk\flutter -Architecture x64

# 独立核验已存在的ZIP，不启动应用。
.\tool\windows\verify.ps1 -FlutterRoot C:\sdk\flutter -Architecture x64 -ZipPath .\dist\windows\PortLink-windows-x64-ID.zip
~~~

ARM64 要在对应 Windows ARM64 主机及 MSVC/ATL 组件下使用 -Architecture arm64；此路线未实测。没有向 Windows Flutter 命令传入无效的 target-platform override。

构建与打包共用 build/portlink-windows.lock 独占句柄，防止边构建边复制；不会杀进程或清除其它缓存。仍不要在同一 checkout 手工并行启动其它 Flutter build/test。

### 输出与完整性

- build/windows/架构/runner/Release：原生 Release 树。
- build/windows/架构/portlink-build.json：正常入口、锁文件/EXE hash、Flutter/VS/ATL/JNI 诊断，不含用户密码。
- dist/windows/PortLink-windows-架构-时间-ID：便携目录及同名 ZIP，不覆写旧产物；失败 stage 留作诊断。
- ZIP 内 portable-manifest.json 记录全文件 SHA256/长度；同目录 .sha256 和 .verification.json。验证在新临时目录安全展开，再比对每个文件 hash、长度和文件数，而非仅检查 ZIP 能打开。

必须保留整个目录，不可只复制 portlink.exe。Inspector 检查：EXE、Flutter engine、当前注册插件 DLL、AOT data/app.so、ICU、Flutter manifest、四状态托盘 ICO、NativeAssetsManifest、cnativeapi DLL。EXE/DLL/AOT 均解析 PE32+ 架构与普通/延迟导入；非系统 DLL 必须 app-local。native manifest 不得包含开发主机绝对路径、越界路径或缺失 DLL。符号链接、路径归一化逃逸、敏感配置及 Debug kernel 被拒绝。

~~~text
dart tool/windows/verify_bundle.dart --bundle <stage-directory> --arch x64 --plugins windows/flutter/generated_plugins.cmake
~~~

原始 Release 未加入 app-local CRT 时可能正确报缺 DLL，正式校验针对 package stage。

## 已核对的原生兼容点

1. 缓存 flutter_secure_storage_windows 4.2.2 原生实现包含 atlstr.h，因此 ATL 是实际编译依赖。缺 ATL 时不能跳过 secure storage 或回退明文。
2. cnativeapi 0.5.2 hook 在 Windows 构建 cnativeapi.dll，C++17/Win32 event loop，链接 Windows 系统库。托盘来自 native assets，不保证出现旧 tray plugin DLL，不能只按历史插件名打包。
3. jni 1.1.0 src CMake 在 Windows/JNI 可用时创建 target jni，输出 dartjni.dll，却将 delay-load 属性写到 TARGET_NAME。项目现有 set(TARGET_NAME "jni")、include generated plugins、unset(TARGET_NAME) 仅修这个作用域，不改 runner、不修改 pub cache。
4. 无 JDK/JVM 时该 Flutter 插件允许 JNI 不可用，不生成 dartjni；PortLink 不使用桌面 JVM。机器发现 JDK 时可能生成 dartjni；仅对 dartjni.dll 延迟导入 jvm.dll 给显式警告，普通缺失 jvm.dll 仍失败。不夹带开发 JDK、不忽略链接错误。TARGET_NAME workaround **不证明** delay-load 链接与运行已通过，要根据 Windows 实际日志复核。
5. build 脚本从 Windows package_config 定位真实 JNI 源并记录 SHA256；升级上游后经审查移除不再需要的 workaround，不静默猜版本。

## 真实 Windows 必须完成的验收

结构报告保留 runtimeSmokeTested=false、authenticodeVerified=false。以下须在 Windows 记录系统/CPU/SDK版本与结果：

- 在非开发环境完整解压并启动正常 EXE，无缺 DLL、CRT、native asset 错误；托盘四状态、菜单、中文、窗口隐藏/恢复与退出。
- UI 输入自有测试服务器密码，不把秘密放进命令、日志或聊天；主机首次人工核验，指纹/算法更换阻断，错密不重试。
- 系统保护凭据读写/更新/删除及应用重启默认连接；配置、备份、ZIP均无密码。脚本不会枚举或读取用户 Credential Manager。
- 3080可用时真实 SSH 多流/半关闭/大响应；被占则安全失败，绝不干扰其它进程。
- 断网、切网、休眠唤醒重连；停止/退出释放监听、SSH sockets、托盘；第二实例不破坏第一实例。
- 公开发行须由用户授权 Authenticode/时间戳与可信分发；脚本不使用用户证书/私钥或提升权限。SHA256只是完整性，不是发布者身份认证。

## 自动证据与运行方式

~~~text
flutter test --no-pub test/tool/windows_packaging_test.dart --concurrency=1
dart analyze tool/windows test/tool/windows_packaging_test.dart
~~~

合成 x64/ARM64 PE 测试覆盖完整目录、AOT架构、插件/native DLL缺失、CRT、普通/延迟导入、JNI警告、畸形PE、敏感文件和路径逃逸。它可在 macOS 运行，不等于 Windows C++ 编译或 PowerShell 执行。当前主机无 pwsh，不额外安装；真实 PS parser、VS构建、ZIP展开和桌面运行仍需 Windows 环境确认。新增test_helpers.ps1覆盖严格版本字段读取、中文UTF8清单、根清单排除/嵌套同名篡改、Release子目录输出拒绝、PS相对路径与完整AOT/DLL/asset构建provenance，但尚未在PowerShell实际执行。ARM64探测支持Hostarm64优先、Hostx64回退，仍需ARM64主机验证。Lead 统一串行执行 Flutter 测试，避免 native assets 并行复制竞态。
