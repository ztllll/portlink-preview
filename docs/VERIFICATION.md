# 开发验证记录

日期：2026-10-23（本机 Apple Silicon，macOS 27.0.1 / arm64）。

## 当前交付性质

**可编译测试的源码预览，不是已完成签名/安装/实机验收的正式应用。当前没有可安装的 `.app` / `.exe` / `.apk` 产物。**

## 已实际执行

| 检查 | 结果与范围 |
| --- | --- |
| 正式依赖解析 | 成功，pubspec.lock已固定 dartssh2 4.1.0、flutter_secure_storage 11.2.0、tray_manager 0.8.0 等 |
| Dart格式 | 33份Dart文件，最终check 0 changed、退出0 |
| 全项目静态分析 | 最终 `dart analyze`：No issues found，退出0 |
| 完整Flutter回归 | **120 passed / 1 skipped，退出0**。41 core/data、40 controller、38 UI、1真实SSH集成；跳过的是需显式开启的截图测试 |
| 真实SSH集成 | 隔离Python环境asyncssh 2.24.1；随机临时服务器密钥；真实密码认证、完整SHA256指纹核对与保存、4并发×128KiB双向数据、半关闭、重连时不重复确认、错密失败、停止释放监听均通过 |
| 核心网络测试 | 真实loopback监听、8并发×256KiB半关闭、端口占用、目标不可达后恢复、探活超时与重连、取消/快速切换/迟到session清理、主机算法变化阻断通过 |
| 配置/控制器测试 | 原子写及验证备份、并发持久化、损坏时fail closed、密码事务回滚、空密码保留、默认选择不切换当前连接、取消指纹/Android启动、shutdown等通过 |
| UI测试 | 新增编辑删除、默认选择、错误展示、指纹主动确认、busy取消、外观真实切换、320–1280宽度布局通过 |
| 预览截图 | 单独开启capture测试：1 passed，退出0；真实Flutter RepaintBoundary渲染。desktop 2560×1800、mobile 780×2880。**模拟配置界面，不代表真实服务器连接或原生安装截图；当前模型不能视觉读图，未声称视觉审阅** |
| Mac配置 | Release/Debug entitlements与Info.plist经plutil校验通过，含出站与监听权限；仅格式/配置检查，不等于系统授权实测 |
| Android配置 | 8份XML解析与主清单结构断言通过；AndroidSession独立Dart分析No issues found；embedding接口已读本地官方源码核对 |
| 原生托盘依赖 | cnativeapi构建钩子在本机命令行工具下产出arm64动态库并用于Flutter测试；不等于菜单栏真实交互通过 |

## 监听端口隔离与本机已有程序

验收时用户既有 Tabby PID1288 正监听 `127.0.0.1:3080`。没有关闭该程序，也没有改变用户的转发配置。首次测试因真实端口冲突正确报错，后续增加明确命名的 `SshTunnelEngine.forTesting(listenPort: ...)` 供自动测试使用隔离端口。

- 正式应用仍通过普通构造固定监听 `127.0.0.1:3080`，没有UI或配置端口变更入口。
- 测试用构造仅替换本地监听端口，目标请求仍是远端 `127.0.0.1:3080`；SSH fixture内部映射至其临时echo服务，避免同机客户端/服务端端口冲突。
- 默认3080被占用时的失败、不重试、不抢占已有程序已测试。
- **尚未在本机完成“正式应用占用3080并连接用户真实服务器”的正向实测**。需要用户先停止已有3080转发。

## 原生构建未完成的具体原因

### macOS

本机 `xcode-select -p` 是 `/Library/Developer/CommandLineTools`，没有完整 Xcode。实际执行：

```text
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -showBuildSettings
xcode-select: error: tool xcodebuild requires Xcode ... is a command line tools instance
exit code: 1
```

已尝试Flutter Mac release构建，但它先下载Mac框架；确认缺完整Xcode后停止无意义的大下载。**没有Mac构建成功记录，也没有安装包、签名、公证、系统Keychain真实读写或菜单栏实机验收**。本轮没有下载/安装Xcode，也未修改系统developer directory。

### Windows

已生成独立Windows工程和插件注册；没有Windows主机/C++桌面工具链，因此未构建EXE，未实测系统凭据存储、托盘或Windows原子文件覆盖行为。工作流仅是源码定义，未上传远端运行。

### Android

`java -version`提示没有Java Runtime；自动探测目录仅包含platform-tools/adb，不是可编译SDK。未安装JDK/Android SDK，未运行Gradle/Kotlin/APK构建，也没有真机后台会话验收。详见[Android验收清单](<ANDROID.md>)。

## 工具链来源

Flutter源从官方GitHub stable分支 `abaf9c523780a608bd46686fd5e53740a07077f8` 归档取得；官方engine revision `deb287481e3ce9468f3434937ced4240a70539ca`，Dart 3.13.5。因直接git/下载通道不稳，在工作区外层 `.tools/flutter` 建立仅供本地工具运行的git元数据并标版本3.47.0；该本地提交不是Flutter官方提交。SDK二进制分块下载后使用官方HTTP ETag MD5核对完整性。`.tools` 不包含在交付源码包中。

依赖和原生模板实际测试以这组版本为准。另一台机器使用官方Flutter 3.47.x仍需重新解析/构建验证；不能把本地工具元数据当官方release校验结果。

## 发布前必须补齐

1. 完整Xcode环境编译运行Mac版，实测安全凭据保存/重启自动连接/菜单栏/睡眠恢复，再签名公证。
2. Windows主机编译并测试托盘、凭据与文件替换。
3. Android具备JDK/SDK后构建debug APK，按真机清单验证通知、切浏览器、停止与进程终止。
4. 使用目标服务器测试实际3080协议与认证；本版只保证SSH password登录，不保证需OTP/MFA/键盘交互的服务器。
