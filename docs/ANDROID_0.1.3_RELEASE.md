# Android0.1.3统一功能与GitHub发布记录

用户2026-10-25明确要求上传Mac安装包，并把Android业务功能与桌面统一后上传。远端main起点f140247，无其他新提交。

Mac0.1.3 ZIP已创建独立预览Release macos-preview-0.1.3，source f140247；官方GitHub资产digest与本地28d0efde92fef8bfa3a9c268de5faa247ca28d5e89b6f898df624f904bc2788c一致。既有Windows发布/tag没有改动。

本次Android差异：共享多端口核心/UI已在前次合并源码中，旧交付APK却未重新构建。本次使用同一shared ForwardRulesEditor/ConnectionPanel，并更新FGS通知不再谎称固定3080；Manifest specialUse subtype同步描述用户配置的listeners/targets，未增加权限。保留唯一Engine/用户发起/通知stop/7秒兜底，没加入boot/sticky/电池绕过。

新增2项Android390×844测试，明确TargetPlatformVariant.android，业务新增/编辑/自定义地址与端口和保存字段通过；首轮使用debug override teardown次序触发测试框架invariant，已改标准variant解决，没有把失败当通过。完整共享247 passed /1 skipped，exit0。

正式ARM64 APK assembleRelease退出0，20,297,837字节，版本0.1.3/code2004，min24/target36，Android Debug证书SHA256079f2be5e1c82946bc00b0824ee9817582103512bce00714ca36408a8d649447。官方apksigner/ELF/NativeAssetsManifest/16KB LOAD与zipalign通过，包SHA2565654fdfb8f8ff619a5a8bd07f08dcc4bb61a780b16f27c54715c1b7d6d81e7e4。签名私钥不上传。

专属AOSP36 ARM64 emulator-5580真实验收：通过UI存双规则18080→127.0.0.1:3080、18081→localhost:3080，经测试专用adb reverse到宿主随机loopback SSH fixture，远端目标仍内部映射随机echo。前台/退Home各双流同时12×64KiB，每条每阶段786432B逐字节相同。真实系统通知显示“多端口SSH转发”，action0点击后FGS与两listener全停；初次按文字匹配误点含停止字样的通知正文只打开App，已改resource-id精确点击再验证通过，不隐去测试偏差。force-stop后新PID恢复规则/安全凭据/指纹并自动连接，无重询。没有读/改用户真实服务器、密码或宿主3080。

原生结果不外推物理手机、手机浏览器、锁屏/Doze/厂商省电，仍需用户验收。图标/菜单Mac平台差异不套给Android；Android用可见通知停止整个多规则会话。

发布将正常push源码到main后，创建android-preview-0.1.3 prerelease，资产仅APK及同名SHA256；不覆盖tag、不dispatch工作流，不把debug签名当正式商店发布。实际URL/上传终态以会话工具核验为准。
