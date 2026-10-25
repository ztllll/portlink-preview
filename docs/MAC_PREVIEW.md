# Mac 本机预览 0.1.0

## 安装与使用

1. 解压交付ZIP，得到PortLink.app，复制到Applications或其他稳定目录。不要把独立原生烟测目标当正常应用；交付包由lib/main.dart构建。
2. 打开应用，添加SSH服务器地址、SSH端口（通常22）、用户名、密码，设置默认服务器并连接。SSH账号必须允许TCP转发，服务在该服务器自身127.0.0.1:3080。
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
- 菜单栏图标创建、原生bounds/可见性读取，窗口显示、真实close回调恰一次且原生NSWindowWillClose计数不增加，确认是隐藏而非真正关闭再重开；随后恢复窗口。不是通过flutter test的mock来冒充原生验证。
- 专用临时配置保存、真实SSH密码认证、外部传入随机服务器指纹比对、数据往返、断开后本地监听释放。
- 新建控制器从临时文件和真实Keychain重新读取默认配置后自动连接，复用host pin不重复询问。此项是控制器重建，不等于用户正式配置跨进程重启/升级全部已验。
- 清理专用测试凭据、临时文件和连接，验收程序最终JSON success:true。

烟测使用本机独立SSH测试服务器、临时本地监听端口，不是用户真实服务器。正式3080仍由Tabby占用；未关闭、未修改该程序。正式使用前请停止Tabby中占3080的转发。尚未实测用户服务、睡眠/切网恢复、肉眼点击菜单的全部路径。

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
