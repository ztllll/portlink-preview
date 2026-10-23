# Android：按需转发会话

## 使用目标与边界

打开 PortLink，在前台开始连接后，把本机 `127.0.0.1:3080` 转发到所选 SSH 服务器的 `127.0.0.1:3080`。切到浏览器/Home 时保留**本次**会话；用完在应用或通知点“停止转发”。Android 14+ 若系统允许划掉进行中通知，划掉也按停止处理，不把通知隐藏后继续转发。这不是 VPN、不修改路由、不监听局域网地址、不提供终端、不设开机启动。注意 Android loopback 不是应用私有网络隔离：同一设备上有网络权限的其他应用也可能连接该端口，所以只在需要时开启，并保留远端服务本身的认证。

FGS 提高当前进程的运行优先级，但不是不被杀、永不休眠或网络永不断的保证。Doze、断网、系统任务管理器停止、强制停止、厂商策略或进程被杀仍会中断。没有部分唤醒锁、忽略电池优化申请、精确闹钟、BOOT receiver、sticky 重启、WorkManager 或定时拉活。Activity 真正结束/划掉最近任务会结束本次会话；单纯切浏览器不结束。Android 12+ 根 Activity 的 Back 可能只把任务移到后台，不能把 Back 手势本身当成“已停止”，使用通知或应用内停止最明确。系统销毁并重建进程时不会从 Service 自动恢复；用户重新打开应用才会按应用设置连接默认服务器。

## 方案与实际连接归属

- Dart `AndroidSession` 仅负责 MethodChannel 协调，不持有另一份 SSH 实现，不引入后台服务插件。
- `PortLinkApplication` 注册生命周期回调但不启动 Engine/Service。只有 launcher Activity 请求时，`SessionRuntime` 才创建一个应用级 `FlutterEngine`，先安装原生通道，再执行默认 Dart 入口。
- 主 Dart isolate 的控制器与 SSH 引擎继续拥有全部 socket、转发 listener、重试和健康检查。UI、Runtime、FGS 都引用**同一个 Engine**。切后台只影响 Flutter 绘制/Activity 生命周期；Android 并不会因为 Activity paused 就自动停止 Dart 异步 I/O。Dart 显式关闭或 Engine/进程销毁才会结束该 isolate 的资源。
- Activity 使用 `provideFlutterEngine` 返回此 Engine，`shouldDestroyEngineWithHost=false`。Service 保留该 Engine 的强引用并处于真正的 foreground 状态，而非只有通知。Service 不创建第二 Engine，不把 Engine attach 到 serviceControlSurface（避免抢走仍需绑定 Activity 的插件）。
- 这仍不是在独立“后台 isolate”迁移连接：UI isolate 卡死时 SSH 与停止回调也可能卡死。原生停止 watchdog 是兜底，不虚构独立后台处理能力。

## 启停协议

1. 控制器创建 `AndroidSession`，先 `setStopHandler(disconnect)`，再 `initialize()`。
2. 在调用 SSH connect **之前** await `start()`。原生等待 Activity resumed；仅从可见 Activity 启动 FGS，绝不靠后台启动豁免。
3. Android 13+ 请求通知权限；支持的最低 API24 起检查应用/会话通知 channel 是否禁用。虽 Android 允许无通知权限启动部分 FGS，本应用为了有清晰可见的停止入口，主动在拒绝时失败，**不开始隧道**。系统设置恢复权限后可重试。
4. 原生调用 `startForegroundService`；Service 立即调用真正的 `startForeground` 成功后才 ack Dart `start()`。若权限、FGS 类型、系统限制或超时失败，Dart 收到错误而不能谎报已启动。初始化前台等待/Service 启动各有 10 秒限时，权限对话框限时 120 秒。
5. 通知“停止转发”、Activity 真正 finishing、划掉任务或意外 Service 销毁，均向同一个 Dart isolate 发 `stopRequested`。控制器必须即使 busy/connecting 也能取消连接、重连 timer 与待确认主机请求。
6. Dart stop handler 必须 await SSH disconnect，成功返回 true。原生在确认前保持可用的 FGS；回调中的 `AndroidSession.stop()` 立即 ack，不会和 stopRequested 互相等待。
7. Dart 停止失败/未安装 handler/7 秒超时：原生 finish 当前 Activity 并 destroy 唯一 Engine，终止拥有隧道的 isolate，再结束 FGS。不是仅移除通知仍偷偷保留 socket。旧停止回调使用代际 token，不可影响新会话。
8. 应用内正常停止顺序：SSH disconnect → `AndroidSession.stop()`。fatal failure 同样停止 FGS；dispose 之前也先清理 SSH。正常停止保留还可见的 UI Engine；最后一个 Activity 已消失且无会话时释放 Engine。
9. Service 返回 `START_NOT_STICKY`；null/未知 intent、旧通知及无当前 Engine 时只 stopSelf，不重建 SSH。

主机信任确认需要用户回到应用；不会在后台自动接受。通知只表示当前转发会话/正在尝试连接，**不是 SSH 已连接或远端服务可用证明**，准确连接状态仍由 Dart 状态流/UI 显示。

## Android 14+ 的用途声明

使用 `specialUse`，而不是假称 mediaPlayback、dataSync、connectedDevice 或 VPN。具体 subtype：

> User-started SSH local TCP forwarding session: exposes only device loopback 127.0.0.1:3080 to the selected SSH server loopback 127.0.0.1:3080 while the user switches to a browser; stops on explicit app/notification stop or task removal. No boot start or persistent background maintenance.

此用途是明确由用户开始、在切换应用时仍需当前连接、可随时停止的本次交互会话。声明应准确反映实际行为；不代表 Google Play 审核或任何设备厂商的批准。本项目侧载自用、不上架；将来若上架需另行审查届时的政策，不扩大本实现权限。

所需 manifest：

- `INTERNET`；`FOREGROUND_SERVICE`；`FOREGROUND_SERVICE_SPECIAL_USE`；`POST_NOTIFICATIONS`。
- application 使用 `dev.portlink.app.PortLinkApplication`。
- 非导出 Service `dev.portlink.app.TunnelSessionService`，`foregroundServiceType="specialUse"`，`stopWithTask="false"`（让 onTaskRemoved 有机会先清理，不是保留已移除任务）。
- Service 内 `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 属性填上述具体用途。
- 不加 BOOT、RECEIVE_BOOT_COMPLETED、REQUEST_IGNORE_BATTERY_OPTIMIZATIONS、WAKE_LOCK 或任何无关权限。

## 已完成的原生接入与构建配置

- MainActivity 已复用 Runtime Engine、禁止宿主自动销毁它，并转发 `onRequestPermissionsResult` 到 Runtime；保留 FlutterActivity 的 super 回调，让其他插件正常收结果。
- minSdk 显式设为 24（直接核验系统通知总开关，无需引入 compat 插件）。compileSdk/targetSdk 沿用本地 Flutter 模板，目前均为 36，满足 specialUse 所需的 API 34+ 编译接口。模板使用 JDK 17、AGP 9.1.0、Gradle 9.3.1、Kotlin 插件 2.4.0；因模板显式关闭 AGP built-in Kotlin，app plugins 块显式应用 settings 中已声明的 Kotlin Android 插件；不另行降级或引入新插件。
- applicationId/namespace 为 `dev.portlink.portlink`，runtime package 为 `dev.portlink.app`；Manifest 使用全限定 Application/Service 类名，通知 drawable 使用 `dev.portlink.portlink.R`。
- 主清单已有 INTERNET/FGS/FGS_SPECIAL_USE/POST_NOTIFICATIONS、准确 subtype 与非导出 Service；另声明 HTTP 浏览器 intent query。没有全局 cleartext 放行。
- 保留插件的自动注册（不要重复手工 register），Manifest 配置 Android embedding v2。
- 禁用 Android 自动备份，以免设备恢复后 secure-storage 密文与 Keystore 不匹配。无需为了浏览器访问 localhost 全局设置 `usesCleartextTraffic=true`：浏览器是另一个应用，PortLink 的 SSH socket 不是 Android HTTP 栈。

## 验证状态与必须实机检查的项目

已使用准备好的 Dart SDK 对 AndroidSession 模块执行独立 `dart analyze`，结果为 `No issues found!`；全部 8 份 Android XML 解析及主清单权限/Service/HTTP query 结构断言通过，并已核对本地 Flutter embedding API。**当前实现未完成 Android 原生编译/真机验证**：原生脚手架现已接入，但此环境的 `/usr/bin/java` 只是启动器，执行 `java -version` 提示找不到 Java Runtime；也没有可用的 Android SDK 编译配置。存在 adb 不等于具备编译工具链。本轮未运行 Gradle/APK 构建，也未验证某个品牌手机的后台行为。不得把“有通知/代码有 FGS”记为隧道已经实测。无 Xcode 不影响本 Android 方案，但不会据此声称其他平台打包成功。

发布 APK 前至少完成：

1. 有 JDK + Android SDK 后运行 `flutter analyze`、`flutter test`、`flutter build apk --debug`；核对 merged manifest、权限和目标 SDK。
2. Android 13+/14+ 真机分别验证通知允许、拒绝、channel 禁用、再次允许。拒绝必须无 SSH socket/listener、无假 ready。
3. 应用前台连接真实 SSH 服务器，浏览器访问 `http://127.0.0.1:3080`（仅当远端3080实际为HTTP），反复切后台/回来，确认会话不重建、请求实际穿过原 SSH 隧道。
4. 保持浏览器页面，通知“停止转发”后确认本机3080不再可连、服务器SSH断开、重连timer停止、通知移除；连接中/等待主机确认时也必须能停止。
5. Home 保持；Activity 真正 finish、最近任务划掉结束；分别记录目标 Android 版本 Back 手势是 finish 还是仅移到后台，不能误判为停止。旋转/配置重建不得启动第二 Engine/重复监听。系统强停后无自启动。
6. 断网/Wi-Fi切蜂窝/服务端3080关闭等按核心状态机处理，不把FGS存活误认SSH ready；fatal failure回收通知。
7. 锁屏与Doze测试只记录实际行为，不承诺免休眠。用 `dumpsys activity services` 核对真实 FGS，再结合端到端请求确认真实隧道，而不是只看通知。
8. 注入停止回调挂起/失败，验证7秒兜底、socket确实消失、可重新打开应用；进程被杀重建也不能从Service复活旧连接。

## 参考依据与本轮联网限制

实现基于 Flutter 外部提供 Engine 生命周期与 Android FGS 的公开接口。官方复核入口：

- [Flutter：添加 Flutter 页面与 cached engine](https://docs.flutter.dev/add-to-app/android/add-flutter-screen)
- [FlutterActivity：shouldDestroyEngineWithHost / provideFlutterEngine](https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html)
- [Android：前台服务类型 specialUse](https://developer.android.com/develop/background-work/services/fgs/service-types#special-use)
- [Android：通知运行时权限与 FGS 的区别](https://developer.android.com/develop/ui/views/notifications/notification-permission)

本轮按 agent-reach 路由用 Jina 读取上述核心资料超时，备用 web-reader MCP 未配置；未取得页面内容，不把这些链接当成本轮已成功抓取的证据，也没有重复做广泛政策调查。随后已读取准备好的本地 Flutter embedding 源码核对：FlutterActivity 的 provideFlutterEngine/shouldDestroyEngineWithHost 支持外部持有 Engine，configureFlutterEngine 不重复注册外部 Engine；FlutterEngine(Context) 自动注册插件，destroy() 明确销毁对应 Dart isolate；Activity onPause/onStop 仅发 lifecycle/处理绘制，onDetach 仅在 shouldDestroyEngineWithHost=true 时销毁引擎。停止兜底先 detachFromFlutterEngine 再 destroy，避免宿主后续向已销毁引擎发消息。仍需 Android 编译与真机端到端验证。
