# Windows / Android 本轮开发与构建授权

2026-10-24用户已明确确认Android构建组件许可/下载，以及私有GitHub上传/Actions构建。已有Mac产物保持不变。私有仓库ztllll/portlink-preview已创建；初次push因当前OAuth缺workflow scope被GitHub拒绝，官方device授权刷新请求曾因网络中断及等待确认超时结束，当前仍缺workflow，需要用户完成官方浏览器授权。Android官方sdkmanager已接受授权的android-sdk-license，SDK/NDK/CMake隔离安装完成，ARM64 APK真实构建与AOSP36运行验收已通过（前后台数据及通知停止）。

## 最新路线：先本地构建、再上传

用户已改为“先继续构建Windows安装包，随后再上传GitHub”，并选择提供Windows x64主机。停止push/Actions/权限刷新；等待Windows主机可操作入口或在该机继续的Harness会话，当前不再以前述workflow权限为本地构建前置。Mac的VMware旧ARM虚拟机记录为broken，对应文件不存在，未擅自新建Windows。接续见WINDOWS_LOCAL_HANDOFF.md。

## 已确认环境

- 本机Apple Silicon Mac。VMware Fusion存在，但vmrun list返回0个运行VM，未找到授权可用的Windows构建主机；工程origin现指用户私有库ztllll/portlink-preview，源码push因缺workflow scope仍被拒绝，仓库当前size=0。
- /usr/bin/java未关联运行时，但Homebrew实际已有JDK17.0.18和25.0.2。Android采用显式JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home，不修改系统Java。
- 已有完整SDK36/35、NDK28.2、CMake3.22及隔离AOSP36 ARM64模拟器运行验收；未连接物理手机。

## 已推进源码

- AndroidSession收口初始化/前台确认取消、停止重入、dispose期间启动拒绝；16项Dart通道mock测试通过，不等同原生APK/真机。
- Windows完整Release目录验证、PowerShell构建/打包/安全展开复验脚本已交付，17项合成PE测试已通过；需Windows实际执行后才能称原生成功。
- Android工具链计划脚本默认只输出JSON，不下载；安装必须显式--install --accept-sdk-license，下载前验证完整JDK17+的java/javac，仍通过sdkmanager让用户审阅许可，不写伪造许可hash、不自动yes。11项计划工具与18项APK/ELF结构合成测试通过。
- Windows脚本额外修复严格模式版本字段读取、UTF8清单、嵌套同名manifest哈希遗漏、完整AOT/native/asset构建来源校验、Release内输出递归和相对路径基准。对应PowerShell helper现已在Mac隔离PowerShell7.6.8实际执行通过，parser也通过；Windows原生构建及PowerShell5.1未验。

## Android 构建准备

```bash
# 默认只展示计划，不下载或接受条款
python3 tool/android/sdk_plan.py

# 仅在用户明确授权接受所需官方许可后，终端交互式安装
python3 tool/android/sdk_plan.py --install --accept-sdk-license

# 工具齐全后，显式变量并串行构建debug APK，检查APK签名
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
ANDROID_HOME="$PWD/../.tools/android-sdk" \
bash tool/android/build_preview.sh
```

官方仓库组件计划约1.28GB压缩下载（含NDK约952MB），安装展开+Gradle/Flutter资产需要更多空间。来源为dl.google.com/android/repository；CLI bootstrap版本19.0、大小/SHA1按官方repository XML固定并核对，SDK/NDK/CMake由sdkmanager安装。SDK许可需获得用户确认，不因一般“继续开发”就自动代同意。

## Windows 可选路径

1. 用户提供Windows11/10 x64主机或已开机虚拟机，具备Visual Studio C++桌面、ATL、SDK/CMake和Flutter；执行Windows脚本。
2. 用户明确允许创建其账号下私有GitHub仓库并上传本项目，运行Actions构建。可能产生账号额度使用；只上传项目源码，禁止用户服务器配置/密码/本机工具缓存。没有授权前不create/push/dispatch。
3. 若暂不提供构建环境，只能交付源码/脚本/合成PE测试，不伪造Windows EXE。

## 当前安装包状态

Android ARM64 Release优化debug签名APK已生成并通过真实AOSP模拟器运行验收，约20.1MB，见ANDROID_PREVIEW.md；Windows EXE/ZIP仍未生成，须完成GitHub官方workflow权限刷新或提供Windows主机。用户授权已收到，不再是等待许可本身。已交付Mac预览不受影响。
