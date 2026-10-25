# Mac 本机预览 0.1.3

0.1.3合并Windows多端口功能：每台服务器最多32条转发，自定义本机IPv4监听/本地端口与SSH侧目标主机/端口，逐规则可用/绑定失败/远端不可达，共享同一SSH会话。Mac与Windows共用业务/UI，保留Mac原生菜单与无Dock行为；详情见[合并说明](<MERGE_WINDOWS_MAC.md>)。schema1可读升级为默认规则，保存写schema2，旧应用不可读取v2。

0.1.2修复原生右键菜单，默认无Dock、隐藏GUI，仅状态栏运行；左键图标直接呼出管理窗口，右键弹出菜单。完整说明见[本轮菜单栏修复](<MAC_0.1.2_FIX.md>)。保留0.1.1的共享SSH并发写入修复和清晰红绿图标：连接/远端探活正常才绿色，未连接、重连、断开或目标异常为红色。图标22pt、44px Retina，不再使用丢失颜色的template模式。大上传验证及诊断边界见[本轮修复说明](<MAC_0.1.1_FIX.md>)。

## 安装与使用

1. 先退出旧PortLink；若旧版状态栏菜单无响应，可在已有GUI按Command-Q正常退出，或在活动监视器选明确的PortLink进程执行正常退出。退出会短暂中断隧道。再解压新ZIP，将PortLink.app复制到Applications或其他稳定目录并打开。不要同时运行两份争用相同本地监听端口；不要删除原配置或钥匙串。不要把独立原生烟测目标当正常应用；交付包由lib/main.dart构建。
2. 打开应用默认只有菜单栏、没有Dock图标；左键状态图标或右键菜单“管理服务器…”呼出完整GUI，添加SSH服务器地址、SSH端口（通常22）、用户名、密码，设置默认服务器并连接。SSH账号必须允许TCP转发，按需编辑转发规则，默认指向服务器自身127.0.0.1:3080；本机绑定非127.0.0.1可能对局域网开放，只有明确需要时才使用。
3. 首次通过服务器控制台/管理员核对SHA256主机指纹。应用不会自动接受未知主机，也不会忽略变化的指纹。
4. 目标是HTTP时可访问http://127.0.0.1:3080；其他协议使用相应客户端。
5. 关窗口隐藏到菜单栏，菜单可重新打开管理窗口；明确退出会先清理隧道、等配置提交/回滚。下次打开自动连接默认配置。

## 系统与分发边界

- 本预览最低macOS13。真实嵌入的cnativeapi/objective_c原生库minos为13，不能根据Flutter框架最低12就承诺macOS12可用。
- 构建为包含arm64与x86_64的通用Mach-O，实际运行验收在Apple Silicon macOS27.0.1、Xcode27.1完成；Intel和旧系统未实机测试。
- 当前是ad-hoc本机预览签名，没有Developer ID身份、没有苹果公证。codesign结构检查通过不等于Gatekeeper认可。下载到另一台Mac可能被系统阻止；不要关闭Gatekeeper或自动移除quarantine。若来源可信，用户可使用系统设置提供的“仍要打开”流程，但正式公开分发应先完成Developer ID签名和公证。
- Keychain使用系统登录钥匙串。重新编译/ad-hoc签名改变可能触发授权或旧项访问差异；不保证未验升级场景无提示，不会回退明文。

## 已实际验证（隔离原生烟测）

- 发布模式真Flutter Mac沙盒进程，真实系统Keychain写入/读回/删除专用随机测试项。
- 隐藏启动且LSUIElement=true、原生activationPolicy=accessory；在专属进程通过AppKit当前右击事件与原button handler触发实际菜单，记录真实tracking并选择管理动作后窗口可见，左键直接show，状态更新后右键再次通过。
- 菜单栏图标创建、原生bounds/可见性读取，窗口显示、真实close回调恰一次且原生NSWindowWillClose计数不增加，确认是隐藏而非真正关闭再重开；随后恢复窗口。不是通过flutter test的mock来冒充原生验证。
- 专用临时配置保存、真实SSH密码认证、外部传入随机服务器指纹比对、32MiB/512轮持续流逐字节匹配、断开后本地监听释放。
- 独立真实HTTP multipart测试单次32MiB和4路各4MiB同时上传，文件和响应SHA256匹配，响应前不FIN，同连接继续GET；不是用户远端DSH图片实测。
- 原生NSStatusBarButton image：22×22pt/isTemplate=false，ready绿、断开红；像素实测而不只检查资源。
- 新建控制器从临时文件和真实Keychain重新读取默认配置后自动连接，复用host pin不重复询问。此项是控制器重建，不等于用户正式配置跨进程重启/升级全部已验。
- 清理专用测试凭据、临时文件和连接，验收程序最终JSON success:true。

烟测使用本机独立SSH测试服务器、临时本地监听端口，不是用户真实服务器。本轮正式3080由用户正在运行的0.1.1 PortLink占用；没有关闭或修改这个会话。新包需用户自行选择合适时机退出旧版再打开。尚未实测用户服务、睡眠/切网恢复、肉眼点击菜单的全部路径。

## 开发验收复现

```bash
# 必须串行，独立烟测构建会改变同目录build产物
flutter build macos --release --target tool/macos_smoke.dart
.venv-ssh-test/bin/python tool/run_macos_smoke.py build/macos/Build/Products/Release/PortLink.app/Contents/MacOS/PortLink
# 完成后重新构建正常入口，且交付前再次校验签名
flutter build macos --release --target lib/main.dart
python3 tool/verify_macos_bundle.py build/macos/Build/Products/Release/PortLink.app
```

原生烟测需要登录桌面与WindowServer。外部Python环境需asyncssh2.24.1。终态JSON和退出均需成功，不能仅因Mac进程exit0就判定验收通过。测试与正式入口切换的增量构建可能保留旧父bundle签名；应生成新bundle或正常清理重建，不用codesign --deep --force掩盖。
