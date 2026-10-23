# Windows / Android 本轮开发与构建授权

用户已要求继续两端，保留现有Mac产物不变。当前未上传源码至任何远端，也未代用户接受Android SDK许可。

## 已确认环境

- 本机Apple Silicon Mac。VMware Fusion存在，但vmrun list返回0个运行VM，未找到授权可用的Windows构建主机；工程没有Git remote。
- /usr/bin/java未关联运行时，但Homebrew实际已有JDK17.0.18和25.0.2。Android采用显式JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home，不修改系统Java。
- 当前只有adb/platform-tools，无完整SDK36/NDK/CMake，也没有连接Android设备（adb devices列表为空）。

## 已推进源码

- AndroidSession收口初始化/前台确认取消、停止重入、dispose期间启动拒绝；16项Dart通道mock测试通过，不等同原生APK/真机。
- Windows完整Release目录验证、PowerShell构建/打包/安全展开复验脚本已交付，17项合成PE测试已通过；需Windows实际执行后才能称原生成功。
- Android工具链计划脚本默认只输出JSON，不下载；安装必须显式--install --accept-sdk-license，下载前验证完整JDK17+的java/javac，仍通过sdkmanager让用户审阅许可，不写伪造许可hash、不自动yes。11项计划工具与18项APK/ELF结构合成测试通过。
- Windows脚本额外修复严格模式版本字段读取、UTF8清单、嵌套同名manifest哈希遗漏、完整AOT/native/asset构建来源校验、Release内输出递归和相对路径基准。对应PowerShell helper测试已写入但本机无pwsh，尚未实际执行。

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

Windows EXE/ZIP未生成，Android APK未生成；下一阶段依赖上述授权或用户提供现成工具/构建主机。已交付Mac预览不受影响。
