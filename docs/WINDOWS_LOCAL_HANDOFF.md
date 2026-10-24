# Windows x64 本地构建交接

## 当前路线

2026-10-24用户要求“先继续构建Windows安装包，随后再上传GitHub”，随后选择“提供Windows x64主机”。因此暂停源码push、Actions和GitHub权限刷新，先在该Windows主机编译。业务授权已收到；当前缺的是主机实际可操作入口，不再把workflow权限作为本路线前置。

实施会话当前在Apple Silicon Mac。本机VMware没有运行VM，旧Windows11 ARM清单记录标broken且对应vmx文件不存在；没有启动、安装或修改其他虚拟机。未收到Windows x64主机远程入口或在该机运行的Harness会话。

## 最省操作的接续方式

1. 将本次构建输入ZIP带到Windows x64主机，解压到普通可写目录，例如C:\work\portlink。它是源码构建输入，**不是Windows安装包**。
2. 在Windows上打开Harness并选择解压目录作为工作目录，告诉Agent：“先在这台Windows x64编译PortLink，成功打包后再上传GitHub。请从docs/WINDOWS_LOCAL_HANDOFF.md继续；不得上传密码或绕过系统安全限制。”
3. 若已有安全配置的远程终端，也可以向原会话说明可用连接名称/入口；不要在聊天发送Windows密码、GitHub令牌或签名私钥。未收到入口前原Mac会话不能操作该机。

## 必需工具链

- Windows10/11 x64（不是Mac上的PowerShell，也不是Windows ARM64）。
- 官方Flutter3.47+、Dart3.13+的Windows SDK，先确认flutter --version和flutter doctor -v。不要复制Mac的.tools SDK或.dart_tool。
- Visual Studio/Build Tools：Desktop development with C++、x64 MSVC、CMake、Windows10/11 SDK，及匹配toolset的x64 C++ ATL。仅有VS Code不够。
- 依赖/engine首次准备需要访问官方依赖源；不需要GitHub仓库，不运行git push或Actions。安装前遵守该Windows主机用户/组织许可与权限，不自动接受新产品条款。

## 由Agent在Windows执行

以下C:\sdk\flutter是示例路径，必须换成实际已安装SDK；在项目根目录的普通PowerShell执行。若系统阻止脚本，先审核/签署，不降低执行策略，不用ExecutionPolicy Bypass，不关闭SmartScreen/防病毒。

```powershell
.\tool\windows\check_syntax.ps1
.\tool\windows\test_helpers.ps1
.\tool\windows\build.ps1 -FlutterRoot C:\sdk\flutter -Architecture x64 -ResolveDependencies -RunTests
# 只有上一条成功后继续；复制完整Release和app-local CRT，再展开核对全部哈希。
.\tool\windows\package.ps1 -FlutterRoot C:\sdk\flutter -Architecture x64
```

脚本遇错误应停下，保留真实日志，修好后重跑；不要删除Assert-Windows或伪造build-provenance。完整说明见WINDOWS.md。

## 预期产物与验收

- 成功后dist/windows下生成完整便携目录和ZIP，以及.sha256/.verification.json。ZIP必须含portlink.exe、data、原生插件/asset和所需CRT，不能只交付EXE。
- 这是最简便携安装包：解压整个ZIP后运行，不写注册表或设置开机启动。尚未正式签名，不宣称SmartScreen无提示，不要求用户关闭安全保护。
- 包结构校验不等于桌面实测；继续验托盘/隐藏恢复、配置与系统保护凭据、真实SSH测试服务器的3080、启动自连和退出释放端口。只用隔离fixture，不索取用户真实密码。
- build.ps1的共享测试在无显式PORTLINK_SSH_TEST_PYTHON时跳过真实SSH测试，应如实记录，不把跳过说成已执行。已有Android178项共享回归和AOSP运行结果不能当Windows桌面实测。

当前Windows EXE/ZIP未生成；待主机连接后才可记录实际编译结果。已有Android/Mac交付不变。本包内没有.git、macOS本机缓存、服务器配置/密码或签名私钥。
