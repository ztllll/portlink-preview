# 本地构建脚本审查补充

安装与远端上传仍待用户明确确认；自动续工作不是许可接受/私库上传授权。本轮没有SDK下载、没有sdkmanager许可接受、没有Git remote、没有仓库创建/push/Actions dispatch。

## 已修并本地可执行验证

- Android APK校验器现在对每个.so验证有界ELF头、ABI机器类型、共享对象类型、program-table/LOAD范围、16KB LOAD对齐诊断；校验NativeAssetsManifest实际库引用、唯一安全ZIP路径、读取上限、包名和minSDK唯一锚定行。不是仅看arm64目录名。
- Windows宿主运行APK签名检查时改为java.exe -jar apksigner.jar参数列表，不经过.bat/cmd；测试覆盖含&等字符路径作为单参数。尚未Windows实际执行。
- SDK bootstrap在任何下载前验证java+javac17+且major一致，显式无效Java路径不偷偷fallback；官方归档大小/SHA1验证、解压拒绝重复路径/穿越/symlink，默认仅计划。
- Python实测：11项SDK工具测试与18项APK合成/ELF/工具参数测试全部通过。样本由测试生成，并非真实APK。
- Dart/Flutter完整共享回归177 passed /1 skipped，静态No issues found；Windows17项合成PE包含在其中。

## Windows PowerShell修复（仍待真实解析/执行）

- 先检查版本字段存在，避免StrictMode读不存在字段。
- 哈希清单只排除根portable-manifest.json，不遗漏嵌套同名文件；JSON显式UTF8以支持PS5.1中文路径。
- 输出不得在Release源树内，检查现存祖先junction；相对路径以PowerShell位置而非.NET旧当前目录为准。
- 成功构建记录完整Release/AOT/native/assets哈希与依赖锁，打包前持共同lock再次比对，避免runner EXE不变却夹入其他target的AOT。
- ARM64主机优先Hostarm64/arm64，允许Hostx64回退，仍需匹配ATL。
- 新test_helpers.ps1及工作流步骤覆盖这些helper路径；本机没有pwsh，此脚本尚未运行，不能以代码已写代替PowerShell通过，更不是EXE构建证明。

## 下一步

获得用户Android组件许可授权后执行隔离SDK准备，串行编译APK并用真实apksigner/aapt检查、再用设备验收。Windows需用户授权的Windows主机或私有GitHub构建；不得自动上传。此前Mac预览ZIP未改变。
