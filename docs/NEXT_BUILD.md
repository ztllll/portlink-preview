# 接续验证清单

更新2026-10-24：用户已安装并初始化Xcode27.1，Mac发布模式正常入口已成功构建，ad-hoc签名结构及arm64嵌入资产验证通过；隔离原生烟测已通过真实Keychain/托盘/窗口/SSH/默认配置重载。完整自动回归仍152 passed /1 skipped，静态No issues found。

## 当前交付

- Mac预览ZIP可解压得到PortLink.app，最低macOS13。不是Developer ID签名/苹果公证发行。具体见MAC_PREVIEW.md。
- SDK在项目外层.tools/flutter，本地自建版本元数据与官方engine revision须区分，不反复重装SDK。
- 生产固定127.0.0.1:3080，Tabby已占用，不得擅自关闭。验收使用临时监听端口，目标仍3080。

## 下一步应优先做

1. 用户停止Tabby占3080的转发后，在正常应用UI填入服务器配置；不得要求在聊天发送密码。验证实际服务协议与连接。
2. 正常应用跨进程重启默认连接、凭据读写、休眠切网恢复和菜单肉眼点击验收。原生控制器重建测试不能替代所有升级/重启场景。
3. 如公开分发，需用户/开发者提供有效Developer ID签名身份与授权的公证流程；不要自动读取私钥、降低Gatekeeper或移除quarantine。
4. Android仍缺JDK/完整SDK，Windows仍需Windows主机；未产APK/EXE，不能把Mac成功写成三端均已验收。当前用户优先Mac，不应自动大规模安装其他工具链。
5. 独立tool/macos_smoke.dart构建会覆盖build的入口，交付必须重建lib/main.dart并验证父bundle签名。若切换target导致App.framework seal不匹配，生成新bundle后正常构建，不使用codesign --deep --force掩盖。
