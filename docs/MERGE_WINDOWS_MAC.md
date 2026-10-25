# Windows / Mac 功能统一合并（2026-10-25）

## 合并输入与历史

- 本机Mac分支：030f441（0.1.2，包含SSH大请求竞态修复、22pt红绿图标、原生右键、无Dock隐藏启动）。
- GitHub origin/main：21448d7，父db9925f为Windows导入根提交；db9925f基于840aafe源码交接包，仅额外增加Windows编译校验器修复/单文件启动器和构建记录，21448d7增加多端口。
- 双方没有Git共同祖先。已先保留backup/mac-0.1.2-before-windows-merge，建立包含两边parent的合并，再以840aafe源码交接基线三方应用远端增量；不是以Mac整树覆盖Windows，也不是强推。

## 业务功能统一

- Mac和Windows共用ForwardRule、ServerProfile、TunnelEngine、规则编辑器与连接面板：每服务器最多32条规则、启停、自定义本地IPv4/端口和SSH侧目标域名/IP/端口；全部规则共用一条SSH会话。
- 每条规则独立监听/目标探测，某条本机端口失败不影响其他规则，不杀占用进程；UI显示逐规则状态及部分可用。
- Mac/Windows菜单均为逐规则复制地址与用户触发HTTP打开，过期规则/未就绪规则不能被旧菜单误打开；wildcard HTTP入口规范化到127.0.0.1。
- Mac平台交互保留原生右键、左键管理、隐藏启动/无Dock、22ptRetina。颜色按此前Mac要求ready绿、其他红；Windows保留远端绿红黄。颜色差异不改变业务状态或功能。
- Windows保留远端ELF64 AOT架构校验、Windows系统DLL清单、launcher.cs和原ICO字节。MacPNG不被远端旧生成器覆盖，PNG生成器不默认改WindowsICO。

## 兼容与修复

- 默认仍loopback3080→server loopback3080；schema1仅缺规则时迁移legacy规则，写schema2。已有schema2完整规则正常读，损坏v2缺rules拒绝并按原子文件策略尝试有效备份，不静默启用错误默认转发。
- 持久化快照和连接运行规则防御性冻结，公开rules不可变，避免认证等待期间被调用方替换；补回归。
- 保留SSH remote.flush竞态修复、超时/取消/清理/半关闭及大HTTP上传回归。原大HTTP测试按新规则API指定随机本地监听，未碰用户3080。
- 旧应用不能读取已写schema2：用户升级前保留配置备份，不用旧版覆盖新配置。监听0.0.0.0可能开放给局域网，界面警告不移除。

## 权限和上传范围

本机gh为ztllll账号，HTTPS git使用gh credential helper，repo scope具仓库push权限但无workflow scope。远端现为public（用户既有状态），不改变可见性；合并后的两工作流blob与远端逐字节一致，不申请或绕过额外scope。此次仅push正常Git合并提交，不上传本机构建缓存、真实配置密码、签名私钥或二进制release，不dispatch Actions，不改既有tag/release。

## 验证记录

- 第一轮完整Flutter回归245 passed /1 skipped，包含核心/数据迁移、UI多规则、桌面菜单、Windows合成包、两项真实SSH（含32MiB+并发HTTP）测试，exit0。7个远端新文件按本SDK格式统一后静态analyze No issues found。
- Windows真实编译成功记录来自用户及远端文档，不是此Mac会话重编译；合并源码须Windows重新构建验证，原EXE不自动更新。远端已记单实例Windows疑点，保留未实测边界。
- Mac原生Release沙盒验收已exit0/success:true：2条独立监听共用SSH，第二条自定义targetHost=localhost、32768字节匹配；逐规则copy/HTTP菜单齐全、右键实际tracking/管理动作、左键呼出/隐藏启动/无Dock均通过，32MiB持续流匹配、两listener停止后可重绑、Keychain与配置恢复通过。Mac不默认拥有127.0.0.2别名，测试仅绑定127.0.0.1的两个随机端口，不修改系统网卡/权限；自定义非loopback监听由跨平台核心测试覆盖。正常lib/main.dart入口0.1.3+4 Release构建、严格签名/本机依赖检查和ZIP重新展开核验已通过。最终ZIP 19,725,722字节，SHA256 28d0efde92fef8bfa3a9c268de5faa247ca28d5e89b6f898df624f904bc2788c；未操作用户监听3080或读取凭据。
