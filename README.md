# HotelWiFi

轻量的原生 macOS WiFi 检查与修复工具。连接酒店 WiFi 后，一键查看本机问题、测试实际联网表现；无法解决时复制诊断给 ChatGPT 继续排查。

**[下载安装包 DMG](https://github.com/NakuTop/HotelWiFi/releases/latest/download/HotelWiFi-macOS.dmg)** · [备用 ZIP](https://github.com/NakuTop/HotelWiFi/releases/latest/download/HotelWiFi-macOS.zip) · [所有版本](https://github.com/NakuTop/HotelWiFi/releases) · [反馈问题](https://github.com/NakuTop/HotelWiFi/issues)

macOS 14 及以上。通用安装包同时包含 **Apple Silicon（M 系列）和 Intel**，使用者无需安装 Python、Homebrew、Xcode 或其他运行环境。

## 安装与首次打开

1. 下载并打开 DMG，把 **HotelWiFi.app 拖进 Applications（应用程序）**。ZIP 用户先解压，再把应用移入 `/Applications`。
2. 从“应用程序”打开 HotelWiFi。**当前发布版使用项目专用证书签名，尚无 Apple Developer ID 与公证**；若提示无法验证开发者/Apple 无法检查，尝试打开后进入 **系统设置 → 隐私与安全性 → 仍要打开**，确认本应用。参见 [Apple 首次打开说明](https://support.apple.com/zh-cn/102445)。
3. 要显示网络名称，点击“允许读取名称”，同意定位授权。应用不采集位置坐标。
4. 要使用需要管理员权限的修复，在应用中点击“修复后台服务”并完成系统批准。普通检查和请求测量可以独立运行。

从此仓库的 Releases 下载即可；“Code → Download ZIP”是源码，不是安装包。校验文件随版本提供，见 `SHA256SUMS.txt`。

## 当前功能与边界

| 功能 | 说明 |
|---|---|
| 本机检查 | WiFi 开关、接口、无线链路、地址、路由、DNS/代理方式、权限及后台状态；可离线执行 |
| 实际联网测试 | 原生请求、完整响应校验、相同对象的前后比较、最终连接复测 |
| 简洁界面 | 主窗口、菜单栏、一键检查并修复、停止并恢复、复制测试报告；没有保存报告和历史页面 |
| 临时 DNS/普通自动代理修复 | 有重复证据且身份、权限、恢复门禁全部通过时才进入实验；无收益恢复 |
| DHCP 配置刷新 | 实现了受限执行器；须确认 DHCP/地址异常并满足用户授权与恢复门禁 |
| 自动重连/切换已保存网络 | 本版执行器受后台身份读取限制，**尚未验证可用**；主应用能读名称不代表后台能重连 |
| AP 持续锁定 | 不支持 |

当前实机验收覆盖 macOS 26.5 / Apple Silicon 的界面、权限刷新、只读请求、后台启动与升级；真实网络写入和跨机管理员服务部署仍需独立验收。编译目标或模拟测试通过不代替实机验证，详见 [验收记录](Docs/VALIDATION.md)。

## 日常使用

1. 连接酒店 WiFi，打开 HotelWiFi。
2. 点击 **一键检查并修复**。程序先检查本机无线链路、地址、路由和修复服务，再测试真实应用请求。
3. 页面直接说明发现的问题、实际操作、相同端点的前后表现，以及最终连接是否通过验证。
4. 没解决时点击 **复制测试报告**，粘贴给 ChatGPT。报告包含本机状态、权限、后台服务故障、原生错误代码、请求结果和已执行操作。
5. **停止并恢复**随时可用。退出前会处理仍由本程序持有的临时配置。

1.2 删除了历史页面、文件导出、首页大对象测速和端点 JSON 编辑器。诊断报告只保留在本次运行的内存中，不自动写入文件；旧版本已存在的历史文件不再读取，也不擅自删除。恢复事务、授权偏好与服务登记状态仍有必要的本机持久化。

## 看不到网络名称

macOS 将 SSID/BSSID 的读取置于定位权限之下。应用会明确区分未申请、被拒绝、系统定位关闭、管理限制、已授权但 API 未返回，以及 WiFi 未连接/已关闭。

点击页面中的“允许读取名称”，或进入系统设置 → 隐私与安全性 → 定位服务，允许 HotelWiFi。应用不读取或保存位置坐标。名称被隐藏并不等于断网，也不妨碍可执行的连通性诊断；需要确认网络身份的写操作仍会受到保护。

返回 HotelWiFi 时自动重读权限和后台能力；“检查到了什么”显示最近核对时间，也可以点击“刷新”。“允许读取名称”“打开定位权限设置”和“重新检查”是分别处理的操作，已授权后不会重复要求授权。重叠刷新会合并，并等到最新一次读取完成后才结束进度提示。

## 离线能做什么

本机 WiFi、电源、无线链路、地址、路由、DNS 配置方式和后台服务检查不依赖互联网。无无线连接时直接给出本机问题，不等待多轮网页超时。轻量 HTTPS 失败后跳过固定对象下载，为恢复保留时间。

已授权且恢复服务真正可用时，可按证据执行：

- 重复解析故障后的临时 DNS 比较与修复。
- 普通自动代理发现的单项实验，保留手动代理、PAC、VPN、受管理配置及分流解析的用途。
- 持续应用请求失败后的单次重新关联。
- 原本使用 DHCP，且 IPv4/IPv6/路由故障成立时请求地址配置刷新，不强占旧租约。
- 在“修复设置 → 更多选项”中选择本次允许比较的已保存网络。

授权保存在本机，升级不自动扩大授权。持续传输、配置原值不明、无法可靠恢复或用户后续切网/关闭 WiFi 时，不进行破坏性操作。已有健康连接不主动重连。没有公开且已验证的持续 AP 锁定能力，不通过连续断网模拟锁定。

新网络的密码、酒店网页登录、酒店设备或出口故障需要相应的外部操作。程序会列出观察事实和未确认原因，并提供 WiFi 设置、登录页面或复制诊断入口，不用“优化成功”掩盖未解决问题。

## 后台修复服务

主应用以普通用户运行。独立 RecoveryGuardian 使用 SMAppService 登记，并仅接受明确列出的网络操作；没有任意命令执行接口。启动文件使用公开的 BundleProgram 键定位包内辅助进程。打包时生成与辅助进程代码哈希对应的服务登记和 SpawnConstraint，随后封装进主应用签名，避免本机证书更新后沿用旧版启动约束。

打开“修复后台服务”完成系统登记与管理员批准。**系统显示已批准，不等于服务能够启动。** 应用还会验证 XPC 响应；已登记但 `EX_CONFIG`、启动失败或超时会直接显示。

默认构建使用本项目专用的本机代码签名证书，不借用其他项目证书，不添加系统信任根、不降低 TLS 检查。固定证书的 XPC 校验与 SMAppService 启动许可分别验证。本机已实测：系统 `/Applications` 安装、原版本更新、再次更新后的 root 启动和 XPC 响应通过。Developer ID 构建可通过环境变量指定签名身份。具体结果见 [验收记录](Docs/VALIDATION.md)。

当前主应用已能读取 WiFi 名称，但 root 辅助进程本次仍无法读取网络身份。自动重连/切网因此显示“暂不可用”，提供“重新检查”和“打开 WiFi 设置”，不再误写成用户未授权。[Apple 关于 daemon 无法获得定位权限的说明](https://developer.apple.com/forums/thread/759044)与本机观测一致；重复授权主应用不能解决这一后台实现限制。只有辅助执行端也实际获得身份，才能开放关联恢复。AP 持续锁定仍无公开且已验证的实现。

失联服务仅在 launchd 明确报告 EX_CONFIG/启动失败且没有运行进程时允许重新登记，并刷新系统应用登记信息；恢复日志原样保留，重启的服务先恢复再接受写操作。运行中或状态不明的服务不会被自动注销。卸载仍要求先确认恢复完成。

## 结果如何判断

系统实际路径用原生 URLSession 请求测量，保留代理/VPN/地址族选择。Apple 和 Google 的小响应及固定对象各自校验，HTTP 200 后超时仍是失败。指定 DNS、IPv4、IPv6、直接 curl 请求仅用于诊断；不会把直接路径成功冒充系统路径已修复。

正常配置比较要求可靠性不下降、改善超过自然波动、在交错窗口重复出现；默认延迟门槛为相对 20% 且绝对 100 ms，是产品参数。没有明确收益时保留原配置。最终当前连接必须重新验证。前后按相同端点和对象展示，少量样本不输出看似精确的高分位结果。

普通流程并发 1、最多 30 MB/180 秒，恢复不因采样预算耗尽而跳过。轻量初测单请求上限 3 秒；固定对象上限 8 秒。监控默认每 60 秒，不持续跑满带宽。

## 命令行

应用内置同一核心的 CLI：

```sh
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi diagnose
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi optimize
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi optimize --dry-run
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi restore
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi monitor --once
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi report
/Applications/HotelWiFi.app/Contents/MacOS/hotelwifi capabilities
```

`report` 现在按需重新诊断并输出，不读取历史报告。支持 `--json`。GUI/CLI 共用授权和独占锁。`optimize` 如果保留临时设置会维持前台会话，Ctrl+C 发起恢复；`--dry-run` 不提交系统事务。

## 构建、安装和卸载

以下仅供源码开发者。普通用户下载上面的安装包即可。开发环境需要 Xcode、Swift 和 Python 3（只用于构建/签名脚本）；已有验收工具链记录见 `Docs/VALIDATION.md`。

```sh
Scripts/test.sh
Scripts/build.sh
Scripts/package-release.sh
Scripts/install.sh
```

默认安装到系统 `/Applications/HotelWiFi.app`，不要从下载、工程或用户 Applications 目录启用后台服务。`build.sh` 分别编译 arm64/x86_64 并合成通用二进制；`package-release.sh` 输出 `dist/HotelWiFi-macOS.dmg`、ZIP 和 SHA-256 校验文件。仅开发本机架构时可设置 `HOTELWIFI_ARCHS=arm64` 或 `HOTELWIFI_ARCHS=x86_64`，这种包不会被发布脚本当作通用包。

已有 1.2 build 9 及以上安装可执行 `bash Scripts/update.sh`：校验相同签名、请求旧应用恢复并注销、保留旧包和恢复日志、安装新版并确认服务实际响应。**普通用户手动更新**：先在旧版停止恢复，在“修复设置 → 更多选项”注销服务，确认完成后退出，再替换应用并按需启用后台服务。不要直接覆盖仍在运行的恢复服务。工程移动后如遇 PCH 旧路径错误，执行 `swift package clean` 后重建。

```sh
HOTELWIFI_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' Scripts/build.sh
```

`.local-signing/` 保存构建者自己的私有签名材料，不进入源码仓库和发布包；接收安装包的 Mac 不需要这些材料，也无需安装证书。自行编译会生成不同证书，不能冒充原发布者或直接通过同签名更新校验。纯只读 ad-hoc 版可设置 `HOTELWIFI_ADHOC=1`。GitHub Actions 用 ad-hoc 包检查构建，正式下载包单独由项目证书签名；CI 不持有私钥，不自动执行真实网络写入。

卸载：在“修复设置 → 更多选项”点击“卸载前恢复并注销服务”，确认已完成后退出，将应用移到废纸篓。不删除用户原有网络配置、钥匙串或网络偏好文件。

## 隐私与验收

复制报告默认移除网络身份、服务名称和标识，不包含密码、门户参数、请求正文或浏览内容。恢复原值保存在受保护的私有事务存储中；字段恢复先比较当前值，保留用户后续修改。

默认测试使用模拟网络/回环服务器，不修改开发机器 WiFi。模拟、实机只读、真实写入分别标记，见 [验收记录](Docs/VALIDATION.md) 与 [真实写入测试范围](Docs/REAL_WRITE_TESTS.md)。

实现参考：[Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[Apple 关于 SSID 定位权限的说明](https://developer.apple.com/forums/thread/732431)、[curl 手册](https://curl.se/docs/manpage.html)。
