# Android 模拟器发现的共享 SSH flush 竞态修复

真实Release APK在AOSP36 ARM64中显示SSH认证和前台服务成功后，持续传输数据失败。错误为dartssh2 SSHTransport._sendAeadPacket调用native Socket.add时遇到StreamSink is bound to a stream。

根因：应用逐块upload在channel sink.addStream之后额外调用remote.flush，dartssh2将其委托到共享TCP Socket.flush。Dart IOSink.flush暂时绑定底层sink，而其他通道异步upload/窗口控制消息仍可调用socket.add。那个flush本身不是SSH channel queue drain，不能提供预期的逐通道背压。

最小修复：移除上传路径remote.flush及ForwardConnection暴露的flush API；保留await sink.addStream。SSHForwardChannel两级map/pipe StreamController将StreamIterator的pause/resume传回source，remote window耗尽时不继续read，保留有界流控和超时。下载方向本地socket只有单writer，仍使用socket.flush。没有修改全局pub缓存或降低依赖版本。

新增测试：暂停的两级channel fixture恢复后完整传256KiB；真实SSH四并发、每流24轮小块request/response，在FIN前等待echo，并以40ms探活交错，原4×128KiB bulk+half-close也保留。2026-10-24 Lead统一scoped analyze No issues found、核心+真实SSH测试exit0（32项）。修复APK已重建并真实通过AOSP36模拟器前台/Home后台各528384B数据匹配与系统通知停止，完整共享回归178 passed /1 skipped；物理手机仍待验。
