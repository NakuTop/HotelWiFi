# 架构与操作边界

## 模块

`HotelWiFi/App` 是 SwiftUI 图形界面和菜单栏，`CLI` 提供自动化入口，两者依赖同一个 `HotelWiFiCore`。`Helper` 是 SMAppService 管理的 root daemon。`Platform` 只桥接 Swift 无法直接导入的公开 IOKit 电源消息宏。

核心职责对应文件：

| 职责 | 实现 |
|---|---|
| CapabilityRegistry / NetworkContext | `Models.swift`、`NetworkInspector.swift` |
| BaselineCollector / ApplicationProbe | `OptimizationEngine.window`、`ApplicationProbe.swift` |
| DNSProbe / 受控诊断 | `DNSProbe.swift`、`ControlledProbe.swift` |
| ProxyInspector / RadioInspector | `NetworkInspector.swift`，仅保留必要摘要 |
| CandidatePlanner / OperationGate | `OptimizationEngine.propose`、`MutationProposal`、`SelectionPolicy.swift` |
| ExperimentRunner / SelectionPolicy | `ExperimentRunner.swift`、`SelectionPolicy.swift` |
| TransactionJournal / RecoveryCoordinator | `TransactionJournal.swift` |
| BudgetManager / PrivacyFilter | `BudgetManager.swift`、`SecureStore.swift` |
| SettingsStore / ReportBuilder | `ReportBuilder.swift` |
| PrivilegedOperations / CallerValidation / RecoveryGuardian | `SystemConfigurationBackend`、`GuardianMain.swift` |

## 信任边界

主应用和 CLI 无管理员权限。SMAppService 需要用户在系统中批准，应用不请求任意 `sudo`，不安装 setuid 程序。root 服务在接受新请求前读取并处理遗留事务；存储、睡眠事件或网络事件注册失败时禁止写入。

双向 NSXPCConnection 支持两种签名要求：Apple trust anchor 加相同 Team ID；或本机项目证书精确指纹 anchor。均限制固定标识：`com.hotelwifi.app` / `com.hotelwifi.cli` / `com.hotelwifi.helper`。服务额外验证当前控制台 UID、audit session、连接 ID、会话 nonce、当前服务和字段。纯 ad-hoc 签名仍被两侧拒绝；专用本机证书无需系统根信任或 Developer ID。`CodeSigningTrust` 检查自身签名、证书用途名称和固定标识，再把同一证书要求用于 XPC 对端。系统后台服务管理员批准独立于签名校验，不被绕过。

输入为最大 512 KB 的 Codable 消息，动作是固定 enum。没有可指定命令、脚本、执行路径、SCPreferences 任意键或任意网络服务类型的接口。DNS 新值仅允许固定的 Cloudflare 或 Quad9 成对地址；代理新值只允许自动发现字段为 0。不会操作代理地址、端口、PAC 地址、例外列表或密码。

root 服务独立读取实际上下文，并在执行时重新核对策略和配置摘要。读取系统 profiles 清单只用于判断是否存在配置描述文件；未知格式或读取失败保持 unknown，任何已安装描述文件保守阻止自动修改。未知不会变成“非受管”。公开 API 返回不了足够身份时禁止写入，不能凭 GUI 的 SSID 文本越过门禁。

## 测量

原生 URLSession 使用 ephemeral 会话、无缓存、无 cookie 持久化，每次请求新建会话，保留系统代理、VPN、平台认证机制和地址族选择；应用不读取或记录认证材料。最多三个同主机 HTTPS 跳转；跨主机、降级 HTTP、带用户凭据的跳转均停止。TLS 使用系统默认校验。

完整成功要求：无请求错误、HTTP 状态符合预期、正文规则满足。固定对象使用 SHA-256 与长度校验。CFNetwork 在超时时可能只在 task metrics 暴露已收到的 HTTP 头和部分正文，因此把 metrics 的字节与 delegate 已收到的字节对账，取较大的计数，避免重复或漏记；不依赖 Content-Length 实施流量预算。

URLSession 与 curl 的 DNS/TCP/TLS 阶段是不同来源。原生 TCP 耗时截止 TLS 开始；curl 累计时间通过相邻差值换算。复用或不存在的阶段保持 nil。指标不包含远端地址、完整响应正文、URL 跳转参数或认证内容。任务 localAddress 仅在内存映射实际接口，持久化接口名和地址族。

独立 DNS 查询使用有长度与边界检查的 UDP DNS 消息；地址随后仅用于 curl `--resolve` 单请求，仍按原域名验证 TLS。指定 DNS 成功只形成候选，不能证明 DNS 未被中间网络转发。单请求直连 / IPv4 / IPv6 不改变任何应用的系统设置。

## 事务与恢复

单事务流程：

1. PREPARE：服务重新读取字段原值、是否存在、授权上下文和到期规则，持久化。
2. ARM：持久化恢复接管状态，并重新读取确认。
3. APPLY：执行门禁；锁住 SCPreferences 后再次比较当前字段，再只修改目标字段。
4. VERIFY：确认实际字段等于本程序所写值。
5. COMMIT：应用层交错复测通过后，由会话持续看护；仍需最终当前连接应用验证。
6. ROLLBACK：比较当前字段，匹配本程序写值才恢复原值；已经被外部更改则记录 conflict。

ARM 是写入前的持久证据，因此写入完成但 APPLY 日志未落盘也能恢复。恢复幂等；重复恢复不产生新修改。日志写入失败时仍尝试用已存在的原始快照清理。日志损坏则阻止新写入，不虚构原值；这是需要人工检查日志的明确故障状态。

提交只延长本次会话有效期，最长 6 小时；10 秒心跳，45 秒失联门槛。XPC 连接失效主动恢复；三秒计时器作为兜底。网络/配置事件立即核对；目标 WiFi Link 重建会结束旧会话，即使新网络沿用同名 SSID。仅 BSSID 漫游不会据此宣称新酒店，也不会生成 AP 锁定能力。

可获得时，身份还纳入系统 NetworkSignature 或当前路由器缓存标识的带密钥摘要，以区分同名、同私有网段的不同网络；没有主动 ARP 扫描。没有这类佐证时只确认会话身份，AP 变化会清理临时配置并要求重测，不把它宣称为已经确认的新酒店。

IOKit 睡眠通知暂停失联判断，唤醒后清理临时修改。重启服务先恢复遗留事务。root 服务从不进行 WiFi 开关、占用旧 IP 或恢复旧路由。1.1 的关联执行器单独见下文。

## 并发、文件与隐私

用户目录使用独占 `optimization.lock`，辅助服务使用 root 目录独占锁和串行队列。不同 GUI、CLI 进程不能覆盖同一恢复事务。敏感恢复文件按目录 fd 读写，拒绝符号链接、额外硬链接、非私有权限和错误所有者。临时文件使用 O_EXCL / O_NOFOLLOW、0600，fsync 后 rename，再 fsync 目录。

本地随机密钥保护持久化网络摘要。会话 nonce 派生的比较身份仅在本会话使用；历史不提供无需复测的自动重放。报告默认移除网络身份和服务名称。原始 DNS 仅位于 root 私有恢复日志，普通报告只保存动作类型和状态。

## 关联与 DHCP 事务（1.1）

`LinkRecovery.swift` 提供共用持久状态机；`NativeLinkBackend.swift` 实现公开 CoreWLAN 关联与 SCNetworkInterfaceForceConfigurationRefresh；`Helper/LinkOperations.swift` 管理 XPC 连接归属、候选缓存、事件核验与单次执行队列。

PREPARE 将原网络及目标材料 AES-GCM 加密到 root 私有文件，独立版本/校验日志引用事务；不包含 WiFi 密码。ARM 确认材料可读及登记落盘后才进入 APPLY。关联在独立 worker 执行，guardian 串行队列继续处理停止、状态及网络事件；系统 API 未返回前禁止第二次关联，避免超时后并发争夺接口。

每一次破坏性请求之前重新采样当前原生路径，防止把早先故障用于已经自行恢复的网络。门禁要求重复完整请求失败（排除门户、TLS、HTTP/body 校验错误及历史过期样本）、已保存且受支持安全类型、可读取的原配置、原关联凭据、当前系统身份和必要的单项授权。持续传输总是阻止；流量低但无法识别会话重要性时默认阻止，只有用户单独允许后继续。接口字节计数不采集目的地址或内容。

候选每分钟最多主动扫描一次、有效期 90 秒，绑定 XPC 连接及扫描时的网络身份。未知 SSID、不在保存列表中或认证类型不支持的网络不进入候选。选中其他网络需要本次确认用途和可能费用，不能只凭名称继承授权；关联时再扫描所选 SSID，不静默换成信号最强的 AP。

恢复最多向原网络发出一次关联请求。关 WiFi、用户修改配置、启动 VPN、切到其他网络、同名 SSID 的不同 AP 环境或无法辨认当前关联时不争夺控制权；重启后不会主动重新加入旧酒店。观察结果分别记录目标 AP 是否实际出现、连接/地址是否就绪和应用请求是否通过。不提供持续 AP 锁定。

DHCP 请求不改配置方式。只接受已配置 DHCP 且 IPv6 确认为不可用、地址/路由故障成立的目标；恢复不保存或强占旧租约，不重复发起续租。

新关联需要两次原生应用窗口及最终当前连接验证才提交。关联比较记录环境变化，不能视为精确 A/B。提交后的无线关联没有临时配置需要反向写回，交由 macOS 维持；正常退出/辅助服务重启不会为了回历史 AP 打断已验证连接。未提交事务由独立服务按上述保护规则恢复。DNS/自动代理的临时字段仍按原流程持续看护并在离网/退出时恢复。

未声称已经在真实酒店上验证这些动作。服务批准、定位/扫描/钥匙串能力和隔离网络验收分别记录在 `VALIDATION.md`。

## 1.2 本机诊断与精简界面

`ConnectionDiagnosis` 根据公开 API 的本机事实、定位权限和真实请求结果生成问题说明和对应操作，不采集坐标。`BaselineCollector` 先测试轻量端点，失败则跳过对象下载，为恢复保留时间。`EndpointComparison` 只比较相同端点/提供商/对象类型的系统路径数据。

`SettingsStore` 仅保存授权与端点设置，已移除 `HistoryStore` 与自动历史写入。GUI 报告只在内存保留，通过 NSPasteboard 复制；CLI report 按需执行只读诊断。私有事务日志仍由独立恢复服务维护。

SMAppService 登记状态、launchd 启动状态与经过身份验证的 XPC 响应分别判断。self-signed 证书校验通过不能证明 root 服务能够部署；未得到响应时不开放写操作。

本机部署验证补充：默认安装位置改为系统 `/Applications`。本机证书辅助进程更新后，BTM 保留旧二进制的 LWCR，重新登记仍被启动签名约束拦截；原二进制对照可启动。现在打包按实际 helper CDHash 生成服务 Label 与显式 SpawnConstraint，并在主应用封装签名前写入。XPC MachService 名称保持稳定，双向证书固定保持独立。更新程序先由旧应用处理事务并注销旧登记，再安装及验证新进程；日志始终保留。失联且无法确认启动失败的服务不能被更新程序自动注销。

GUI 的 Hardened Runtime 签名包含 `com.apple.security.personal-information.location`，打包检查会验证实际签名中的该值。授权流程有即时状态反馈，不调用位置坐标更新。前台授权不会推断为 root 辅助进程也可读取身份；root status 单独报告 associationIdentityReadable，关联恢复门禁据此决定是否可执行。
