# HotelWiFi 1.2 验收记录

日期：2026-10-06。1.1 记录保留于 VALIDATION-1.1.md。本文引用的 `Evidence/` 是开发机本地验收材料，包含机器相关状态，不随公开源码或安装包发布；公开的可复现构建/测试记录见仓库的 Actions 页面。

## 本轮发现

- 用户授权已经开启，原服务状态是 enabled，但 launchd 累计启动失败并返回 78 / EX_CONFIG；系统日志报告无法找到/执行 BundleProgram，root 恢复目录从未创建。
- 工程移动后旧 Swift 模块缓存含绝对路径，清理生成缓存后重新编译。
- 原流程会在断网时继续测对象和地址族，可能耗尽恢复时间；已改为轻量检查优先、失败跳过对象、为恢复保留预算。
- 名称读取现在按定位权限与本地链路分别解释；未知字段不当作网络故障。

## 自动化测试

最新 112 项：111 通过、1 项外网只读测试默认跳过、0 失败。日志：Evidence/permission-actions-tests.log。此前 104 项记录保留在 Evidence/simplification-tests.log。

新增覆盖名称授权/链路断开区分、IPv6-only、缺少地址、端点故障、HTTP200后超时、门户仅为推测、代理/直接路径分离、服务登记与响应分离、可比对象、复制报告脱敏和错误码、无历史文件写入、断网跳过对象与健康对象采样，以及签名约束故障解释、限定的服务标识和只允许修复已确认未启动的服务。

已有恢复故障注入仍通过；跨进程 SIGKILL 使用模拟文件后端，不代表真实系统配置写入验收。

## 构建

SwiftUI、Core、CLI、Helper 和恢复测试程序均已构建。发布包本机签名、独立可执行文件、最低 macOS14 与 arm64 检查通过。日志：Evidence/simplification-release.log。

## 实机验收

- 实机只读 optimize --dry-run：12/12 次完整成功，42,240 字节，最终验证通过，changes 为空。系统网络偏好 SHA-256 和旧 history.json SHA-256 前后相同：Evidence/simplification-readonly-summary.json。
- root 服务：同一签名包在用户 Applications 目录重新登记仍然 EX_CONFIG；移动到系统 /Applications/HotelWiFi.app 后启动成功。随后升级复查发现：系统仍保留原辅助进程的 LWCR，新二进制触发 CODESIGNING / c[5]p[1]m[1]e[0]；相同证书的原二进制恢复后立即运行，形成对照证据。改为辅助进程代码哈希对应的服务登记，加显式 SpawnConstraint 后，新版启动成功，launchd 为 running，经过签名校验的 XPC 返回“恢复服务已就绪”。再次完整更新也通过。未使用 Developer ID，未添加系统根证书或放宽调用者校验。见 Evidence/helper-update-comparison.json、Evidence/simplification-update.log。
- 名称读取：locationd 日志确认旧版 Hardened Runtime 缺少定位 entitlement，因此不发送授权弹窗。已补入签名声明并增加发布包验收。用户已亲自确认“已弹出，允许后能看到名称”。
- 辅助进程身份限制：主应用/CLI 可读取 SSID、BSSID，但 root 辅助进程 status 返回 associationIdentityReadable=false。build 12 将此情况准确标为 unavailable；缺少后台结果则标 unknown，不再误标为用户未授权。自动重连和切网不当作功能通过。AP 锁定为 unavailable。DNS/代理写入还需通过管理状态、恢复及具体证据门禁；服务就绪不等于每种修改都获准。
- 真实网络配置写入、主动重连/切网/DHCP 续租未执行；当前网络健康，不为验收强行打断连接。root 运行与 XPC 响应已验证，不代表所有写操作均做过实机测试。
- GUI 布局由编译和运行检查；未进行自动截图视觉验收。复制报告的脱敏/错误码构建有单元测试；系统剪贴板交互尚无自动端到端测试。

## build 12–13 权限提示与按钮回归

- 修复“打开定位权限设置”误调用授权流程、在已授权状态下只刷新而不打开设置的问题。操作标签和目的地集中定义；系统设置 URL 已通过本机 LaunchServices 解析测试，目标为 com.apple.systempreferences。
- 前台已能读取名称、后台不能读取身份时，提供重新检查和 WiFi 设置动作；不提供无效的重复授权动作。新后台结果可用后，相应提示消失。
- 返回主应用自动刷新；重叠刷新串行合并，调用方等待最新一轮完成。并发测试覆盖授权在首次读取期间变化，验证两次读取没有并行、所有调用方返回时均为新状态。
- 复制报告使用最近核对的权限和后台能力并标明时间；网络请求样本仍保留原始测试时间。
- build 13 已通过真实窗口的 Accessibility 点击验证：重新检查按钮返回新的状态反馈、WiFi 设置和定位设置按钮打开对应系统页面、返回 HotelWiFi 后最近核对时间改变。系统网络偏好文件哈希和用户策略均不变。结果：Evidence/permission-actions-ui.json。没有点击网络或权限开关。
- build 13 同时修复设置面板中的同类按钮：已授权时明确显示“打开定位权限设置”，不再提供含义不符的“允许读取”动作。

## 1.2.0 build 14 公开分发

应用功能沿用 build 13；网络事件回调显式声明内部 Task 的弱引用，兼容较早 Swift 编译器的并发检查。默认构建改为 arm64 + x86_64 通用包，最低系统目标为 macOS 14；提供可拖入 Applications 的 DMG、ZIP 和 SHA-256 校验文件。签名私钥、恢复日志、诊断记录、旧安装备份不进入源码或安装包。

GitHub Actions 在 macOS 14 / Apple Silicon 和 macOS 15 / Intel 上执行默认模拟/回环测试、通用构建与包验证；执行结果以对应提交的 Actions 状态为准。CI 使用 ad-hoc 签名，不承担需要用户批准的特权服务验收。正式发布使用项目专用证书，尚未 Developer ID 签名或 Apple 公证。

独立 Mac 的首次 Gatekeeper 确认、定位授权、root 服务登记和真实网络写入仍需用户设备或隔离网络验收。CI 虚拟机不替代这些测试。
