# 本次原生构建授权与执行记录

2026-10-24用户在明确列出两项动作后回复“确认”，随后回复“继续”：

1. 允许下载本项目Android SDK/NDK/CMake等官方构建组件，并代表用户接受本次构建所需官方组件许可。
2. 允许在当前已登录GitHub账号下创建私有仓库、上传项目源码并使用Actions构建Windows版。可能使用账号Actions额度。

## 限定范围

- 不上传用户服务器配置/真实密码、签名私钥、凭据库、工作区.tools、.dart_tool、build/dist或其他本机缓存。已跟踪内容经清单核对仅为源码、测试、工程、图标与验证文档。
- 远端为ztllll/portlink-preview，已通过GitHub API确认private=true。没有创建公开仓库。
- 首次git push被GitHub拒绝：当前OAuth App缺workflow scope，远端仓库当时size=0，不能上传工作流。已使用官方gh auth refresh请求该权限；直连曾超时，使用系统现有代理后获得设备代码，但等待用户确认超时，当前scope仍为gist/read:org/repo。需要用户在本机终端执行gh auth refresh -h github.com -s workflow并完成官方浏览器确认；不改用其他身份/API绕过权限。
- Android下载至项目外层.tools/android-sdk，已有JDK17显式复用，不改系统Java或developer directory。使用官方sdkmanager展示并接受android-sdk-license，未伪造license hash。
- Mac已交付ZIP保持原样，Windows和Android的原生构建及设备实测状态以各构建日志为准，不把本授权或源码测试当作原生产物成功。

一次性设备授权码只在当前会话中展示，不写入仓库。完成构建后仓库归用户账号所有；正式发布签名/商店上传/公开分发不包含在本次许可中。
