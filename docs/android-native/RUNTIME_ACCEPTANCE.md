# AOSP36 ARM64 Release 运行验收

2026-10-24，Apple Silicon Mac + 官方Android Emulator37.2.12，独立portlink-api36 AVD，serial emulator-5580；未操作物理设备。使用最终修复APK，SHA256 f81c4de163f46339f0212ed740b5f775dfc5991e26e3a1c942290ba3f3f6efed。

## 实际通过

- adb install Release ARM64 APK成功，MainActivity冷启动Status ok，app PID存在；不是widget mock。
- 真实UI添加专用RuntimeFixture配置，通知权限对话框实际点击允许，完整随机服务器SHA256指纹与本地隔离SSH fixture一致后勾选信任；认证与服务探测到ready。
- 首次测试发现共享native flush竞态，已最小修复并重建；历史初版hash49da...不再交付，也不算运行成功版本。
- adb install -r覆盖修复APK后冷启动，配置/系统安全存储密码/host pin恢复并自动连接，无重复指纹确认。仅fixture凭据，不读用户密码。
- 真实dumpsys确认TunnelSessionService isForeground=true；前台及Home后台分别12轮请求/响应，前4轮1KiB+后8轮64KiB，每阶段528,384字节逐字节匹配，保持长连接等待每次echo再发下一请求。
- 下拉系统通知UI看到实际“停止转发”action0，真实点击后service消失、app界面未连接，ADB映射3080读不到任何数据，已断监听。
- 修复后专用app logcat无Unhandled Exception/StreamSink bound。系统镜像无网络时自身BestClock告警不算app错误。

## 边界

数据路径是专用模拟器127.0.0.1:3080 -> 真实Dart SSH -> 测试用adb reverse随机宿主SSH服务 -> fixture本机随机目标echo。目标请求仍断言服务器127.0.0.1:3080，再由fixture映射内部echo，未占用宿主3080或连接用户服务器。adb forward自身不能作为半关闭证明；半关闭用本机真实SSH回归保留测试。

补充：在同一AOSP36模拟器中通过应用“打开 HTTP 页面”真实启动系统WebView Browser Tester133，127.0.0.1:3080页面显示本机隔离HTTP SSH fixture的随机标记，浏览器前台时PortLink FGS仍为前台。另经系统测试命令撤销通知权限（Android可结束应用进程），确认服务/监听消失；从启动器冷启动并在真实系统对话框拒绝通知后，连接失败、无FGS、3080无数据。不把这个结果说成已验证Android后台通知timer。物理手机、锁屏、厂商省电、Android7~15覆盖、真实用户SSH服务器和正式签名升级仍待用户验收。最终APK仍为debug证书签名的Release优化侧载预览，不是商店正式发布。
