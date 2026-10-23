# 1.3.0 验证记录（2026-10-23）

本次修复针对 VPN／代理开启时酒店认证检测不到、默认浏览器继续走代理的问题。

## 实现

- 一键修复先通过 NWConnection 绑定 WiFi 接口并 preferNoProxies，读取 Apple HTTP 认证检测响应。六秒超时，最多 32 KiB，不保存跳转地址和响应正文。
- 跳转、511 或成功页面被替换时进入认证流程，不继续执行 DNS 实验或反复断线。
- 内置 WKWebView 使用非持久网站数据和专属 SOCKS5 代理；随机本机端口、每次独立随机凭据，不允许代理失败后回落到普通网络路径。SOCKS 上游绑定当前 WiFi，TLS 仍由 WebKit 正常校验。
- 登录检测通过后重新运行原生 HTTPS 测量，独立 WiFi 检测成功不等于正常系统路径成功。
- 网络变化触发节流的认证检测；可在修复设置中关闭自动检测。
- 登录窗口关闭、停止、无线链路变化、休眠、退出或等待五分钟后清理通道。认证窗口不向默认浏览器打开外部协议。

## 已完成

- 修改前：112 项测试，1 项外部只读测试跳过，0 失败。
- 修改后：123 项测试，1 项外部只读测试跳过，0 失败。
- 无线评分测试覆盖弱 5 GHz 不胜过强 2.4 GHz、未知信号、明显候选推荐与报告隐私；评分不等于实际吞吐。
- 实机在系统代理开启时完成独立 WiFi HTTP 检查，并在正常系统路径最终复测中通过三个请求；未执行系统配置修改。随后一轮实机出现系统路径请求不稳定，独立 WiFi 检测仍可达；已增加诊断分流与防止重复结果项的回归测试。代理链路不稳定的具体外部原因尚未确定。这不是一次待认证酒店的登录验收。
- 新增 HTTP 成功／跳转／511／页面替换／服务故障分类、旧报告解码、诊断动作、本机目的地址限制。
- 真实 loopback TCP 测试验证 SOCKS5 用户名密码认证及 HTTP 传输。
- WebKit 实际请求测试使用 .invalid 域名，验证浏览器经过认证 SOCKS 通道到达本地 HTTP 页面，避免 loopback 自动绕过代理造成假通过。

## 待真实环境验收

- 具体酒店的认证门户、房号、验证码、跨域／弹出页面和认证后的放行状态。
- 开启真实 VPN／PAC／SOCKS 客户端时，WiFi 绑定是否被全局过滤、TUN 或断网保护阻止。
- macOS 14 实机与 Intel 设备；编译通用包不代表完成实机验收。
- 既有特权 DNS／DHCP／重连流程沿用旧版权限与恢复门禁，本次测试不代表这些生产写入已完成酒店实测。

Apple HTTP 检测站点自身故障仍可能与酒店拦截混淆；页面替换是认证线索，不是酒店身份验证。请核对页面域名与酒店说明。

参考 API：
- https://developer.apple.com/documentation/network/nwparameters/requiredinterface
- https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations
- https://developer.apple.com/documentation/network/proxyconfiguration
