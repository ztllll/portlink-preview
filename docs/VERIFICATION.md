# 开发验证记录

更新：2026-10-25（本机 Apple Silicon，macOS 27.0.1 / arm64，完整Xcode27.1已安装并初始化）。

## 当前交付性质

**Mac发布模式应用已构建、打包并在本机通过隔离原生烟测；交付为ad-hoc签名预览ZIP，不是Developer ID签名/苹果公证的正式发行版。Android ARM64 Release预览APK已构建并通过官方签名/ELF/16KB检查，已通过AOSP36 ARM64真实运行验收（前后台数据与通知停止），物理手机待验；Windows已有用户在x64主机构建并提交的版本及构建记录；本次Mac合并未重新执行Windows原生编译，合并源码需Windows再构建。** 详细安装和验收边界见[Mac预览说明](<MAC_PREVIEW.md>)。

## 已实际执行

| 检查 | 结果与范围 |
| --- | --- |
| 正式依赖解析 | 成功，pubspec.lock已固定 dartssh2 4.1.0、flutter_secure_storage 11.2.0、tray_manager 0.8.0 等 |
| Dart格式 | 51份Dart文件（含原生验收和Windows包检查入口），最终check 0 changed、退出0 |
| 全项目静态分析 | 最终 `dart analyze`：No issues found，退出0 |
| 完整Flutter回归 | **合并版245 passed / 1 skipped，退出0**。覆盖多规则核心/配置迁移、共享UI、原生桌面协议、Windows合成包、2真实SSH集成（含32MiB HTTP上传）；跳过的是需显式开启的截图测试 |
| 真实SSH集成 | 隔离Python环境asyncssh 2.24.1；随机临时服务器密钥；真实密码认证、完整SHA256指纹核对与保存、4并发×128KiB双向数据、半关闭、重连时不重复确认、错密失败、停止释放监听均通过 |
| 核心网络测试 | 真实loopback监听、8并发×256KiB半关闭、端口占用、目标不可达后恢复、探活超时与重连、取消/快速切换/迟到session清理、主机算法变化阻断通过 |
| 配置/控制器测试 | 原子写及验证备份、并发持久化、损坏时fail closed、密码事务回滚、空密码保留、默认选择不切换当前连接、取消指纹/Android启动、shutdown等通过 |
| UI测试 | 新增编辑删除、默认选择、错误展示、指纹主动确认、busy取消、外观真实切换、320–1280宽度布局通过 |
| 预览截图 | 单独开启capture测试：1 passed，退出0；真实Flutter RepaintBoundary渲染。desktop 2560×1800、mobile 780×2880。**模拟配置界面，不代表真实服务器连接或原生安装截图；当前模型不能视觉读图，未声称视觉审阅** |
| Mac配置 | Release/Debug entitlements与Info.plist经plutil校验通过，含出站与监听权限；仅格式/配置检查，不等于系统授权实测 |
| Android配置 | 8份XML解析与主清单结构断言通过；AndroidSession独立Dart分析No issues found；embedding接口已读本地官方源码核对 |
| 桌面退出协议 | 通过注入托盘/窗口替身验证窗口隐藏、故障关闭前清理、Flutter原生退出请求等待、重复退出幂等、菜单更新结束再销毁、相同错误不反复抢焦点、过期HTTP菜单不启动；不是原生App安装测试 |
| 单实例 | macOS上真实子Dart进程验证锁冲突、同isolate重复拒绝、进程终止后锁释放；未占用TCP端口。Windows文件锁待Windows实测 |
| 退出保存事务 | 退出等待已接受的配置提交、密码回滚和删除清理，连接/指纹等待取消不死锁；启动部分失败也释放服务和锁 |
| Android Dart协议 | 16项MethodChannel mock测试通过，含初始化期间停止、晚到FGS确认、重复停止、dispose期间拒绝重入；不能替代Kotlin/真机验收 |
| Windows包结构测试 | 17项合成PE样本测试通过，覆盖x64/ARM64、EXE/DLL/AOT架构、普通/延迟import、依赖缺失、native manifest与路径安全；Mac隔离PowerShell7.6.8已通过脚本解析及纯逻辑helper；仍无Windows主机，未执行Windows原生构建/ZIP验收 |
| Android构建工具测试 | 11项SDK计划/JDK版本/授权保护/安全解压与18项合成APK/ELF/清单/工具参数测试通过；此前为合成测试；2026-10-24用户授权后真实SDK/NDK安装与APK构建已通过，结果见下方原生记录 |
| 构建诊断 | 历史三目标退出2；安装Xcode后Mac检查已退出0，Android/Windows此前缺前置状态未变；10项注入测试覆盖完整Xcode、SPM/CocoaPods、JDK/SDK/NDK/CMake、SDK版本和端口占用；不会安装组件或终止占用者 |
| Mac钥匙串配置 | 通过真实插件MethodChannel mock验证write/read/delete携带usesDataProtectionKeychain=false且无共享group；移除受限Keychain Sharing权限。现已在真实ad-hoc签名沙盒烟测中完成专用凭据写入/读回/删除；用户正式凭据及升级兼容仍待验 |
| Mac产品配置 | Xcode27.1完整Release构建退出0，正常入口PortLink.app约49.2MB（0.1.2）；主程序和4个framework均含arm64/x86_64，严格签名结构校验通过；实际native库最低13，工程声明已同步13，Release不再注入get-task-allow |
| Mac0.1.2原生菜单栏模式 | 启动hidden/LSUIElement=true/accessory无Dock；实际AppKit右击button handler触发NSMenu tracking、选择管理后show，左键show，状态更新后再次右击成功，关闭hide不终止隧道；全局真实鼠标点击未注入 |
| Mac0.1.1大流量/红绿图标 | 原生32MiB/512轮53.221秒匹配；NSStatusBarButton image实测22pt、非template、ready绿/断开红；HTTP32MiB+4×4MiB上传及持久连接通过，不能代替远端DSH复现 |
| Mac真实原生烟测 | 独立沙盒Release入口，真实Keychain/托盘原生bounds/窗口显示与真实close事件恰一次且NSWindowWillClose未增加、隐藏恢复/SSH往返/监听释放/默认配置重载自连/专属凭据清理均通过，终态success:true；不是mock，不是用户真实服务器 |
| Mac正常入口启动 | 旧版正常入口启动/退出曾验；0.1.2正常入口在用户旧实例运行时存活、系统activationPolicy=1、安全拒绝重复连接且新进程无TCP，保留旧7707监听未动，仅终止测试进程。完整功能用独立原生烟测验，未代用户跨版本重连；烟测退出Engine handle invalid警告保留 |
| Windows原生依赖 | 对jni1.1.0未定义TARGET_NAME的条件性Windows路径增加受限作用域兼容值；只读源码/结构检查，仍待Windows配置链接验证 |
| 原生托盘依赖 | cnativeapi构建钩子在本机命令行工具下产出arm64动态库并用于Flutter测试；不等于菜单栏真实交互通过 |

## 监听端口隔离与本机已有程序

初次验收时用户既有 Tabby PID1288 正监听 `127.0.0.1:3080`；0.1.1修复验收时此端口由用户旧PortLink PID2818监听。两轮都没有关闭既有程序或改变用户的转发配置。首次测试因真实端口冲突正确报错，后续增加明确命名的 `SshTunnelEngine.forTesting(listenPort: ...)` 供自动测试使用隔离端口。

- 正式应用仍通过普通构造固定监听 `127.0.0.1:3080`，没有UI或配置端口变更入口。
- 测试用构造仅替换本地监听端口，目标请求仍是远端 `127.0.0.1:3080`；SSH fixture内部映射至其临时echo服务，避免同机客户端/服务端端口冲突。
- 默认3080被占用时的失败、不重试、不抢占已有程序已测试。
- **尚未在本机完成“正式应用占用3080并连接用户真实服务器”的正向实测**。需要用户先停止已有3080转发。

## 原生构建与平台状态

### macOS（2026-10-24已解除工具链阻碍）

用户安装完整Xcode27.1，xcode-select已指向/Applications/Xcode.app/Contents/Developer，版本和首次初始化检查均退出0。发布正常入口lib/main.dart完整构建退出0，PortLink.app约49.2MB（0.1.2）；ZIP约19MB，ditto保留bundle结构，重新展开后codesign --verify --deep --strict与所有嵌入Mach-O的arm64检查通过。

最初App声明12但cnativeapi/objective_c真实minos13，现已把工程最低版本同步13；Release显式禁止注入base entitlements，最终实际权限无get-task-allow。托盘应用最后窗口关闭策略设false，原生烟测验证关窗后的存活/恢复和连接清理。

当前签名Signature=adhoc、TeamIdentifier=not set，没有Developer ID或公证；spctl实际拒绝，该限制没有通过删除quarantine或关闭系统安全来绕过。原生烟测专属数据与失败尝试的测试项已精准清理，未读取/修改用户真实凭据。0.1.2验收证据位于[本轮原生记录](<macos-0.1.2/native-smoke.json>)及[包结构记录](<macos-0.1.2/bundle-verification.json>)；历史0.1.0/0.1.1记录保留。

### Windows

用户已在Windows11 x64完成构建并推送；远端db9925f/21448d7的文档记录Flutter3.47.8/Dart3.13.7、VS2022 BuildTools/ATL/SDK和便携包核验成功，Windows实机交互与单实例疑点仍按远端文档保留。本Mac会话合并其ELF64 AOT校验器、系统DLL白名单、单文件启动器和多规则功能，不把用户构建记录宣称成本机重编译。合并源码0.1.3需Windows再次构建；工作流未修改或启动。

### Android

用户2026-10-24明确确认后，复用JDK17.0.18，官方sdkmanager隔离安装SDK36/35、build-tools36、NDK28.2、CMake3.22及platform-tools，官方许可正常接受。真实assembleDebug退出0（通用包约158MiB）；assembleRelease ARM64分ABI退出0，20,116,139字节。官方apksigner确认Android Debug证书，ELF架构/native manifest/minSdk24/targetSdk36、16KB LOAD和zipalign检查全部通过；这是Release优化的debug签名侧载预览，不是正式发布签名。KGP未来兼容warning保留，不是本次失败。物理设备未连接；AOSP36 ARM64模拟器真实安装、持久化恢复、前台/Home后台各12轮528384B匹配、通知停止后FGS退出/3080不再服务均通过。首版暴露flush竞态，修复后APK重建复验成功，最终哈希f81c4de163f46339f0212ed740b5f775dfc5991e26e3a1c942290ba3f3f6efed。补充通过应用按钮打开系统WebView测试浏览器，localhost3080随机标记HTTP页面成功、FGS后台存活；系统撤销权限后服务/监听消失，冷启动拒绝通知时无转发。锁屏/物理机Chrome/厂商省电未验。详见[Android预览](<ANDROID_PREVIEW.md>)和[原生包记录](<android-native/fixed-arm64-verification.json>)。

## 工具链来源

Flutter源从官方GitHub stable分支 `abaf9c523780a608bd46686fd5e53740a07077f8` 归档取得；官方engine revision `deb287481e3ce9468f3434937ced4240a70539ca`，Dart 3.13.5。因直接git/下载通道不稳，在工作区外层 `.tools/flutter` 建立仅供本地工具运行的git元数据并标版本3.47.0；该本地提交不是Flutter官方提交。SDK二进制分块下载后使用官方HTTP ETag MD5核对完整性。`.tools` 不包含在交付源码包中。

依赖和原生模板实际测试以这组版本为准。另一台机器使用官方Flutter 3.47.x仍需重新解析/构建验证；不能把本地工具元数据当官方release校验结果。

## 发布前必须补齐

1. Mac已完成本机发布构建与隔离原生烟测；仍需用户真实服务器、正式3080、跨进程重启/升级凭据兼容和睡眠切网验收，公开分发前Developer ID签名及公证。
2. Windows主机编译并测试托盘、凭据与文件替换。
3. Android已完成ARM64 APK与AOSP模拟器前后台/通知停止验收；仍需物理手机的浏览器、锁屏、厂商省电、进程终止和用户真实服务器验收。
4. 使用目标服务器测试实际3080协议与认证；本版只保证SSH password登录，不保证需OTP/MFA/键盘交互的服务器。
