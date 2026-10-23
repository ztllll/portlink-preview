# 隔离 PowerShell 本地执行记录

日期：2026-10-24，Apple Silicon macOS27.0.1。

## 工具来源与隔离

- 官方仓库PowerShell/PowerShell发行v7.6.8，资产powershell-7.6.8-osx-arm64.tar.gz，70,634,622字节。
- 官方hashes.sha256校验表（UTF16）对应SHA256：c16a3f433966c6fd5a9c8a660a95c92cb5dbc4b1813416501d1ba30ca160da32，下载后按体积与SHA256实际比对通过。
- 只解压至工作区外层.tools/powershell-7.6.8；未通过pkg/brew装到系统，未添加系统PATH，未设置执行策略。关闭了该进程的telemetry/updatecheck环境选项。
- 未下载Android SDK、未接受Android许可、未创建远端仓库或上传源码，未启动Windows VM。

## 实际执行

```text
.tools/powershell-7.6.8/pwsh -NoLogo -NoProfile -File tool/windows/check_syntax.ps1
exit 0: PowerShell parser accepted all Windows scripts

.tools/powershell-7.6.8/pwsh -NoLogo -NoProfile -File tool/windows/test_helpers.ps1 -TemporaryRoot /private/tmp
exit 0: Helper tests passed

.tools/powershell-7.6.8/pwsh -NoLogo -NoProfile -File tool/windows/build.ps1
exit 1: Requires a real Windows host. Nothing was installed or built.
```

helper覆盖版本metadata三种字段形态/缺字段拒绝、UTF8中文路径清单、嵌套同名manifest纳入哈希且篡改拒绝、AOT/DLL/asset变化使旧build provenance失效、Release内输出拒绝且不创建目录、PowerShell Set-Location与.NET当前目录不一致时正确解析相对路径，以及原生命令exit7会传播为失败。所有文件只在新建临时测试目录生成并收尾。

第一次使用macOS默认临时目录时，输出祖先含symlink被路径安全检查正确拒绝；改用明确/private/tmp后通过，没有降低防junction/symlink限制。

## 证据边界

这是实际PowerShell7脚本执行，不再只是人工语法审查；但运行平台仍是Mac。没有Visual Studio编译、Windows原生托盘/凭据/文件锁实测、WindowsPowerShell5.1执行或Windows ZIP展开成功证据。不得把helper通过当成EXE已构建，也不得移除Assert-Windows以伪造产物。
