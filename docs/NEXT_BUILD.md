# 接续构建清单

本轮已完成跨平台源码、真实SSH/并发/配置/UI测试、桌面退出协调/单实例及Android通道协议测试。最终141 passed /1 skipped，静态No issues found。不要再次把这些验证写成原生安装包验收。

## 当前未改变的具体环境条件

- Mac：/Applications/Xcode.app不存在，xcode-select仅/Library/Developer/CommandLineTools；xcodebuild -version实际报requires Xcode。已准备项目内.tools/flutter和依赖，但缺完整Xcode不能执行Flutter原生Mac应用构建。
- Android：/usr/bin/java只是启动器，java -version无runtime；仅platform-tools不等于SDK。没有原生Kotlin/APK编译。
- Windows：没有Windows主机/Visual Studio C++桌面工具链。
- 用户Tabby PID1288占127.0.0.1:3080，不允许擅自停止；测试用临时监听端口，生产固定3080。

## 下一轮应优先做

1. 只检查工具链是否变化，不重复下载已存在的Flutter SDK或再次尝试不可能的Xcode构建。
2. 如完整Xcode已安装并完成首次启动，可用项目外层.tools/flutter/bin/flutter构建Mac；本地SDK引导使用FLUTTER_PREBUILT_ENGINE_VERSION=deb287481e3ce9468f3434937ced4240a70539ca。不要混淆本地git元数据与官方SDK提交。
3. 无Xcode时可继续有限且有价值的原生可编译性静态核对、发行脚本校验，但不要无限增添首版以外功能掩盖无法产安装包。Xcode下载/账户授权/首次许可证是需要用户操作的现实前置。
4. 若环境条件不改变，应保留“原生构建待完成”的状态并说明缺少什么，不以重复通过源码测试替代可安装产物和实机验收。

## 完成标准仍未满足

- 可运行Mac应用，真实菜单栏/系统安全存储/休眠恢复验证；签名公证如公开分发。
- Windows至少在对应工具链编译；Android按需会话至少编译APK并真机切浏览器/停止。
- 用户真实服务器与正式3080正向链路验收。不要要求用户在聊天中提供SSH密码。
