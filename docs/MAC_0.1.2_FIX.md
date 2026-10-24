# Mac 0.1.2：原生右键菜单与无Dock启动

## 问题与改动

用户已确认0.1.1图片发送恢复；本次不改变SSH转发/密码/主机指纹策略，仅修菜单栏交互与启动方式。

- 原先右键事件经nativeapi到Dart，再在Dart回调同步FFI调用OpenContextMenu/NSStatusBarButton.performClick；这个路径在AppKit菜单追踪中有重入/线程问题，先前仅验图标存在没有验右键。现在为Mac明确配置公开nativeapi ContextMenuTrigger.rightClicked，由AppKit原生事件线程自动打开菜单；Dart右键回调不二次popup。
- 左键直接打开/聚焦管理窗口；右键菜单“管理服务器…”也可呼出。连接状态变化后重新绑定原生trigger，避免重建菜单丢交互。
- LSUIElement=true，不显示Dock图标（包括管理窗口打开时）。窗口visibleAtLaunch=NO，正常启动保持隐藏；从状态栏呼出后完整GUI照常使用，点关闭仅隐藏，隧道继续。
- FlutterViewController通常等viewWillAppear才run engine；完全隐藏窗口会导致Dart和托盘都未启动。已在原生awakeFromNib显式运行已有engine，不通过闪主窗口启动。
- 手动打开的窗口不被晚到finishStartup再次隐藏。首次指纹确认、错误/托盘失败仍有可见处理入口，不自动信任、不把失败藏起来。

## 已验证

- 26项桌面集成测试全部通过（新增10项启动/手动show/菜单与异常可见性测试），静态分析No issues found。
- 真正macOS Release沙盒烟测exit0+success:true：启动windowHidden=true、LSUIElement=true、activationPolicy=1（accessory）；无先show再hide。
- 在专用fixture进程内建立实际AppKit currentEvent/rightMouseUp，调用当前NSStatusBarButton原处理器，记录NSMenu.didBeginTrackingNotification=true，实际native菜单action选择“管理服务器…”后Dart窗口可见。连接后再右键第二次同样通过；不是仅直接调用Dart onTray回调。为避免影响用户，未做全局鼠标点击或请求辅助功能权限。
- 同一路径leftMouseUp可显示GUI、不打开第二菜单；show后仍accessory无Dock，晚到finishStartup不遮已打开窗口。真实close callback只一次、窗口隐藏而非销毁，隧道仍ready。
- 原生红绿22pt/非template、32MiB 512轮流、Keychain专用测试项、默认配置恢复/自连、断开释放监听均通过。
- 第一次隐藏启动烟测发现engine没运行并精准修复；第二至四轮测试事件未建立NSApp.currentEvent、没有触发button回调，未当成成功；第五轮完整原生事件/菜单验证通过。所有测试项已清理，未读取用户密码或修改当前7707会话。
- 完整Flutter回归199 passed /1 skipped，exit0；包含两项真实SSH集成和大HTTP上传回归。正常lib/main.dart入口Release构建、codesign严格验证、ditto ZIP重新展开后结构验证均通过。正常入口独立进程系统NSRunningApplication核对activationPolicy=1；用户旧实例仍占3080，新实例没有TCP连接，验证后仅终止测试实例。
- 最终ZIP约19.62MB，SHA256：495e08508d1773cb28a0689fbe6c07ff1f10aa5800c241775eeaec1993572943。原生烟测退出仍有Flutter Engine handle invalid提示（历史已知退出警告），不宣称无警告。

## 升级与使用

本轮没有中断用户正在运行的0.1.1实例。旧版菜单无响应时，可先在已有GUI中使用macOS标准退出（Command-Q/应用退出），或在“活动监视器”选择明确的PortLink进程执行正常退出。退出会短暂中断隧道；不要随机终止其他程序或删除配置/钥匙串。

然后解压新ZIP，替换稳定位置的PortLink.app再打开。第一次打开默认只有菜单栏：左键图标直接管理；右键弹菜单，可管理服务器/停止/退出。无默认配置也默认隐藏，点击图标添加。首次SSH指纹或明确错误可自动呈现GUI以便处理。

仍为ad-hoc本机预览、未Developer ID签名/公证；不关闭Gatekeeper、不绕过SmartScreen/防病毒或移除quarantine。登录钥匙串访问因签名变化可能正常提示，使用系统授权，不回退明文。
