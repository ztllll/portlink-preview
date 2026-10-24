# Mac 0.1.1：图片上传与状态栏修复

## 用户问题与已知事实

2026-10-24用户反馈：通过PortLink访问远端DSH时，纯文字正常，发送图片报session/prompt Failed to fetch (gateway/internal)；状态栏图标过小且难区分状态。

核对到当前运行的是此前交付的0.1.0 Mac应用，不含后续Android运行测试发现的共享SSH写入竞态修复。当前源码已修复：不对dartssh2共享TCP sink逐通道调用flush，避免其他通道异步socket.add碰到IOSink暂时binding。这个问题能造成断流，但仅凭截图不能证明它就是本次DSH故障的唯一原因。没有读取用户密码、用户服务器配置，未终止当前应用或占用其3080。

PortLink生产转发为透明TCP/direct-tcpip，不解析图片/HTTP内容，无总body字节数阈值。现有保护是128条并发本地连接、单次阻塞写30秒超时、连接/认证/探活超时；不是单文件大小限制。远端DSH、反向代理或模型接口可能有独立限制，不等于PortLink无总限就保证任意大小的DSH图片成功。

## 本次改动

- Mac预览版本升级0.1.1+2，首次将此前共享SSH竞态修复重编译到Mac交付。
- 所有状态栏写入isTemplate=false保留颜色，22pt显示尺寸，显式44px Retina资源、粗实心图形和明暗描边。ready绿色勾，idle/pending/failed等非ready均红；探活失败不保留绿色。
- 打包脚本从bundle版本生成文件名，拒绝覆写现有输出。旧运行版本、密码和配置不动，用户手动退出旧版再替换。

## 已执行的验证

- 真实SSH multipart HTTP上传回归：单文件32MiB，另4路并发各4MiB，16KiB分块。服务端流式核对文件字节数和SHA256，客户端核对完整JSON及响应hash；先等待HTTP响应、再同连接GET /alive，不依赖FIN。测试exit0。使用模拟图片二进制、随机loopback端口，不是远端DSH实测。
- 全套Flutter回归189 passed /1 skipped，exit0；新增10项图标状态/调用参数/实际PNG像素与1项大HTTP回归。格式48份Dart无变化，analyzer无问题。
- 真Mac原生Release沙盒烟测exit0且success:true。32MiB在512轮持续请求响应中逐字节匹配，耗时53.221秒，超过30秒而不中断，证明30秒不是总上传期限。原生NSStatusBarButton image实测22×22pt、isTemplate=false，红状态1006个红像素/0绿、绿状态952绿/0红。真实Keychain、默认配置恢复自连、关闭隐藏和停止释放监听均通过；退出仍保留此前Flutter engine teardown警告，不宣称无警告。

## DSH报错的只读核查（仅本机打包版本）

本机DSH公开程序包0.2.1-rc.3已编译lib的读取证据：

- dsh-client-connection/lib/index.js 26–30：默认HTTP JSON RPC请求体300MiB；54–78在声明长度/累计接收超限时返回413。
- dsh-attachment-local/lib/index.js 895–904：默认单张图片20MiB、每条20张、合计200MiB、6400万像素、单边8192。准入后4MiB/2048²归一化目标不是上传硬阈值。
- dsh-api-gateway/lib/client.browser.js 1819–1839与2115–2139：session/prompt是HTTP unary调用；fetch/传输抛错会在客户端包装为同截图的client api: session/prompt failed: Failed to fetch (gateway/internal)，不是必然为服务端内部错误。
- 图片在prompt里是JSON/base64；multipart回归是对透明TCP大请求的压力验证，不假称精确复现DSH序列化。真正图片准入超限通常映射session/attachment-invalid，而可见HTTP超限通常带HTTP413；但被中间层/断连遮蔽响应时仍不能仅凭报错排除超限。

以上仅核对本机公开程序文件，未读用户配置/日志/凭据，未连接用户远端DSH，因此不能推定远端也是同版/同默认值，也未修改DSH自身限制。

## 使用与仍需确认

新包已由正常lib/main.dart入口构建并重新展开验证，ZIP SHA256：d57b5b70a1747cb84222102f1b45bedd271f0cd6d490ab955efd5d5ffe445ae6。请先在旧PortLink菜单选择退出（会短暂中断隧道），再打开0.1.1；不要同时开两份占3080。若Keychain因ad-hoc身份变化提示，使用系统正常授权；不关闭Gatekeeper、不删除钥匙串或回退明文。

升级后请用同一张图片复测DSH；若仍失败，需要浏览器开发者工具中失败请求的状态/错误类别、图片大小和远端网关的脱敏错误信息以区分网关/模型限制。不要发送SSH密码或完整私密会话数据。预览仍为ad-hoc、未Developer ID签名/公证。
