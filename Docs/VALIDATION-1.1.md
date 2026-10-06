# HotelWiFi 1.1 验收记录

验证日期：2026-10-04，Australia/Sydney。1.0 的历史证据保留在 `VALIDATION-1.0.md`；以下是本机证书与关联/地址恢复增强版本。

## 构建和签名

环境：Apple Silicon arm64、macOS 26.5（25F71）、Xcode 26.3、Swift 6.2.4、SDK 26.2；最低部署目标 macOS 14。源代码、release `.app`、CLI、root helper 和 ZIP 已构建。用户运行无需 Python、Homebrew 或 Xcode。

三个可执行文件均由本项目专用的本机代码证书签名。Security API 自检及实际发布文件的 certificate anchor / identifier 检查通过；错误证书、相同 bundle identifier 的 ad-hoc 冒充文件被原生代码要求拒绝。证据：`Evidence/local-signing-verification.json`。这些静态检查不代替 root XPC 部署验收。

构建只使用隔离的项目钥匙串，结束后恢复原搜索列表并锁定；不添加系统信任根、不修改 TLS 验证。Developer ID 不再是本机功能的必要条件。macOS 对 SMAppService 的管理员批准仍是必须满足的系统授权；注册结果以运行时状态和 `Evidence/local-helper-registration.json` 为准，不将签名验证等同于服务已获批准。

构建日志：`Evidence/enhancement-release.log`。当前有一项兼容性警告：公开的 `SecKeychainSetUserInteractionAllowed` 已弃用；它只用于禁止 CoreWLAN 系统钥匙串读取弹出交互。未使用私有 airport、私有 AP 锁定 API 或任意 root 命令执行。

## 自动化测试

`swift test -j 4`：**83 项，82 通过、1 默认跳过、0 失败**。证据：`Evidence/enhancement-tests.log`。默认跳过外部只读端点测试；正常测试不访问外部网络、不注册服务、不修改本机 WiFi。

新增 21 项在 `LinkRecoveryTests`：专用证书要求、历史策略默认关闭新权限、健康连接与业务保护、DHCP/手动配置/IPv6 边界、候选授权、门户/TLS/陈旧失败排除、ARM/磁盘失败、崩溃后的单次恢复、用户切网和关 WiFi、同名 SSID 的其他 AP、重启后的断开状态、目标 AP 与实际 AP 分离、提交后保留可用连接、两窗口验证、VPN/配置冲突、加密材料和脱敏、并发/三次上限，以及快速准备/执行检查下的流量门禁。

已有独立进程 SIGKILL 测试仍然通过，使用真实持久文件和模拟配置后端；**不代表 root launchd 服务已在真实网络上恢复成功**。关联故障测试也不调用 CoreWLAN 真实关联。

## 功能状态

| 功能 | 实现状态 | 实机验证边界 |
|---|---|---|
| 无 Developer ID 的特权入口 | 本机证书固定、普通用户 GUI/CLI、SMAppService root helper | 签名要求已实测；系统批准以当前状态为准 |
| DNS/普通自动代理字段 | 保留事务、比较后恢复和交错测量 | 未做本轮真实配置写入 |
| 当前网络重新关联 | 公开 CoreWLAN 单次请求，凭据/业务/授权门禁 | 编译和模拟恢复通过；未主动中断当前工作 WiFi |
| 所选已保存网络/AP | 扫描、本次选择、费用确认、连接/网络身份/90 秒令牌，读取实际结果 | 系统定位、扫描和钥匙串权限须实机满足；未进行真实切网 |
| DHCP 恢复 | 公开刷新接口，原 DHCP 方式、IPv6/地址/路由及应用失败检查 | 未对正常租约发出续租 |
| AP 持续锁定 | 不提供；公开 API 不保证维持指定 AP | 不用重复断网模拟锁定 |
| 退出/离网恢复 | 未提交关联单次恢复；已验证关联交给系统维持；DNS/代理临时字段清理 | 真实崩溃、睡眠/唤醒、离网与重启场景待隔离网络验收 |

## 实机只读与界面

本轮签名版 diagnose 和 optimize --dry-run 各完成 12/12 个完整请求，各计入 42,240 字节，最终应用验证通过，changes 和 activeTemporary 均为空。系统网络偏好文件的测试前后 SHA-256 相同。证据：`Evidence/enhancement-readonly-summary.json`。这不代表真实配置写入或关联已经验证。

安装目标 `~/Applications/HotelWiFi.app`，执行签名验证并启动。应用通过原生系统调用请求注册后台服务；批准需要用户在 macOS 界面完成，不能用程序跳过。应用没有自动开启新策略授权。

本轮界面工具确认 Mac 处于锁屏状态，无法完成窗口与按钮验收。SMAppService 已返回 requiresApproval（原始值 2），注册错误为 SMAppServiceErrorDomain / 1，尚未运行 root 服务。需要用户解锁并在系统设置批准；未代填管理员凭据，也没有将这一步标为通过。

## 尚未完成的验收

- 真实 DNS/代理写入、CoreWLAN 重新关联/切网、DHCP 恢复，以及相应进程崩溃/系统重启后的恢复。
- 本机签名的服务批准与 root XPC 调用者校验全流程；目前系统状态为 requiresApproval，Mac 处于锁屏状态，不能由静态签名测试替代。
- 企业 VPN/分流 DNS、门户、计费/低数据、系统钥匙串拒绝和真实持续业务情况下的行为。
- macOS 14 运行、Intel 构建、长时间监控和公开分发公证。

测试方法见 `REAL_WRITE_TESTS.md`。当前正常网络不满足故障门禁时，正确结果是零写入；没有为了完成验收撤去这些门禁。
