# Android 0.1.0 ARM64 侧载预览

## 当前安装包

- PortLink-0.1.0-Android-arm64-preview.apk，Release优化构建，arm64-v8a，20,116,139字节；用于大多数64位Android手机。
- minSdk24（Android7.0），targetSdk36。ARM64分ABI版本码为2001，版本名0.1.0。
- **使用Android Debug证书签名，仅供本次侧载预览**，不是正式发布签名，也未上架。签名私钥不随源码或安装包交付；签名证书本身是APK公开签名信息。
- SHA256：f81c4de163f46339f0212ed740b5f775dfc5991e26e3a1c942290ba3f3f6efed。

## 使用

1. 将APK传到自己的Android手机，按系统提示允许此次安装来源安装；不要关闭系统安全保护。
2. 打开后添加SSH服务器IP/域名、SSH端口、用户名和密码，保存并连接。请在应用内输入密码，不发到聊天。
3. Android13+需要允许本次转发通知；本版拒绝没有可见停止入口的会话。
4. 首连通过另一可信渠道核对完整SHA256主机指纹，再信任；不确定就拒绝。
5. 手机浏览器访问127.0.0.1:3080（HTTP服务用http://），这指手机自己，不是Mac。服务需在SSH服务器自身127.0.0.1:3080运行。
6. 切到浏览器可保留本次会话，用完在应用或通知点停止；不做长期保活、开机自启或系统强杀自动复活。

## 已验证与未验证

- 真正Gradle assembleDebug及ARM64 assembleRelease均退出0，没有Kotlin编译错误；KGP未来兼容警告保留，不冒充无警告。
- 官方apksigner verify通过，真实APK的ELF机器类型/架构、native manifest库引用、包名/minSdk检查通过。所有嵌入ELF LOAD满足16KB对齐；官方zipalign -c -P16 -v4通过。
- 修复后共享178项Flutter回归及Android16项MethodChannel测试已通过，但mock测试不等于原生设备运行。
- AOSP ARM64 API36隔离模拟器已真实安装/冷启动，通过UI保存配置、系统通知授权、指纹核对、覆盖安装后凭据与指纹恢复自动连接；前台及Home后台各12轮528,384字节往返匹配。真实通知“停止转发”后FGS退出、UI未连接且3080停止服务，修复后logcat无Unhandled/StreamSink bound。补验应用按钮打开系统WebView测试浏览器，127.0.0.1:3080实际显示随机测试页面；撤销/拒绝通知后不再转发。物理手机、手机Chrome等其他浏览器、锁屏与厂商省电行为仍未验收。
- App数据禁备份，SSH密码走系统安全存储；跨设备迁移、卸载后保留、正式签名升级不在此预览保证范围。

Windows仍待GitHub官方workflow权限刷新，私有库创建本身不是EXE构建成功。Mac原预览ZIP保持不变。
