# Windows 构建、便携打包与验收

## 合并后状态（2026-10-25）

本次Mac会话已读取并保留远端db9925f/21448d7的Windows构建记录、ELF AOT校验器、系统DLL清单和launcher.cs。下方Windows成功记录来自远端已提交文档及用户确认，不是本机Mac重新执行Windows编译；合并源码0.1.3需在Windows再build/package，旧release不自动含合并改动。Mac多规则编辑/状态/逐规则copy与HTTP菜单现共用同套业务实现，Mac专有无Dock/原生右键保留。

## 当前状态

**2026-10-25 已在真实 Windows 11 x64 主机完成原生编译与便携打包**（Flutter 3.47.8 stable / Dart 3.13.7，VS 2022 Build Tools 17.14、MSVC 14.44、ATL、Windows SDK 10.0.26100）。`build.ps1 -ResolveDependencies -RunTests` 退出 0：177 项测试通过、1 项真实 SSH 测试因未设置 `PORTLINK_SSH_TEST_PYTHON` 而跳过；`package.ps1` 生成 13.6 MB 便携 ZIP，并在新目录展开后逐文件哈希与依赖核验通过。
**仍未做 Windows 桌面实机验收**（托盘四状态、隐藏/恢复、系统凭据、真实 SSH 转发 3080、退出释放端口），也**未做 Authenticode 签名**：`runtimeSmokeTested=false`、`authenticodeVerified=false`。

### 本次 Windows 构建修复的两个校验器缺陷

1. Flutter Windows 的 `data/app.so` 是 **ELF64** AOT 快照而非 PE；旧检查按 PE 解析会误报 `Missing MZ header`。现改为校验 ELF 魔数、ELF64 小端与 `e_machine`（x64=0x3e，arm64=0xb7）。
2. `flutter_windows.dll` 导入 Windows 自带的 `uiautomationcore.dll`、`oleacc.dll`、`d3d9.dll`、`dbghelp.dll`，旧白名单漏掉它们导致误报"未打包依赖"；已加入系统 DLL 白名单（VC 运行库仍必须 app-local）。

### 单文件启动器（tool/windows/launcher）

`launcher.cs` 把已验证的便携 ZIP 作为资源嵌入一个小 EXE：双击后解压到 `%LOCALAPPDATA%\PortLink\app-<ZIP哈希前16位>`，核对 `portlink.exe` 的 SHA256 后启动；不写注册表、不自启、不提权。它不是 Flutter 原生单文件，只是自解压外壳。源文件中的 `__PAYLOAD_ID__`、`__EXE_SHA256__` 是占位符，编译时替换。

### 多端口转发与托盘颜色（2026-10-25）

新增每台服务器多条转发规则、自定义本地监听地址与目标地址；托盘图标改为实心圆（16–256px 多尺寸 ICO），绿/红/黄分别表示已连接/未连接或失败/连接中或部分可用。旧配置（schemaVersion 1）读取时自动升级为单条 3080→3080 规则，写出为 schemaVersion 2；回退到旧版本程序将无法读取 v2 配置。

### 已观察到、尚未解决

连续启动两个 EXE 时出现了两个带窗口的 portlink 进程，应用内单实例锁（`instance.lock`）在 Windows 上疑似未生效，原因待查。

（以下为 2026-10-24 在 macOS 上写下的历史状态，保留备查。）

截至 2026-10-24，实施主机是 macOS，未发现运行中的 Windows VM；**当时尚无 Windows 原生编译或桌面验收结果**。现已在Mac上的隔离官方PowerShell7.6.8中实际执行语法解析和纯逻辑helper回归，均退出0；不等于Windows/PowerShell5.1原生验收。本次提供脚本、缓存源码核对与合成 PE 测试，不能写成“Windows EXE 已构建”。不创建或上传远端仓库，不自动安装工具，不更改签名、执行策略、防火墙或系统安全设置。

转发规则可配置：每台服务器可有多条“本地地址:端口 → 目标地址:端口”规则，共用一条 SSH 会话。默认（及旧配置升级后）为 127.0.0.1:3080 → 服务器 127.0.0.1:3080。某条本地端口被占用时仅该条失败，不自动换端口、不连接未知已有服务、不终止占用者。托盘图标：绿=已连接且全部可用，黄=连接中或部分可用，红=未连接或失败。

## 本次构建顺序

用户已选择提供Windows x64主机，要求先构建安装包、随后上传GitHub。本会话不继续push或Actions，等待实际主机入口；交接见[Windows本地构建](<WINDOWS_LOCAL_HANDOFF.md>)。本机VMware旧ARM VM记录失效，不是可用编译环境。

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

必须保留整个目录，不可只复制 portlink.exe。Inspector 检查：EXE、Flutter engine、当前注册插件 DLL、AOT data/app.so、ICU、Flutter manifest、四状态托盘 ICO、NativeAssetsManifest、cnativeapi DLL。EXE/DLL解析PE32+架构与普通/延迟导入，AOT快照单独校验ELF64小端和机器架构；非系统 DLL 必须 app-local。native manifest 不得包含开发主机绝对路径、越界路径或缺失 DLL。符号链接、路径归一化逃逸、敏感配置及 Debug kernel 被拒绝。

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

合成 x64/ARM64 PE 测试覆盖完整目录、AOT架构、插件/native DLL缺失、CRT、普通/延迟导入、JNI警告、畸形PE、敏感文件和路径逃逸。它可在 macOS 运行，不等于 Windows C++ 编译或 PowerShell 执行。现已从官方发行SHA256校验后，将PowerShell7.6.8便携包解压到工作区外层.tools，不修改系统PATH/执行策略。真实PS parser接受全部脚本；test_helpers.ps1在Mac实际通过版本字段读取、中文UTF8清单、嵌套同名篡改、完整AOT/DLL/asset provenance、输出路径安全、PS相对位置及外部命令失败传播。Mac的默认临时目录祖先含symlink，测试改用-TemporaryRoot /private/tmp，不放宽路径保护。VS构建、Windows ZIP展开、WindowsPowerShell5.1及桌面运行仍需Windows确认。ARM64探测支持Hostarm64优先、Hostx64回退，仍需ARM64主机验证。Lead 统一串行执行 Flutter 测试，避免 native assets 并行复制竞态。
