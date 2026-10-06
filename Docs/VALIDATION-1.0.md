# HotelWiFi 验收记录

验证日期：2026-10-04，Australia/Sydney。本记录区分模拟、只读实机与真实配置写入，不将其中一种通过替代另一种。

## 交付状态

已交付原生应用、共享 Swift 核心、CLI、独立恢复辅助服务源码、自动化测试、安装脚本和中文文档。应用可在本机安装、启动并执行真实只读诊断。当前产物是本地 ad-hoc 签名版本，**没有启用特权网络写入，也没有完成包含真实修改、离网自动清理的完整酒店使用路径验收**。

环境：Apple Silicon arm64，macOS 26.5（25F71），Xcode 26.3，Swift 6.2.4，macOS SDK 26.2。三个发布可执行文件的最低部署版本均为 macOS 14.0；尚未在 macOS 14 机器运行。没有第三方 Swift Package 依赖，用户运行产物不需要开发工具或 Python。

## 构建与自动化验证

| 检查 | 结果 | 证据 |
|---|---|---|
| `Scripts/test.sh` | 62 项：61 通过、1 跳过、0 失败 | 工程 `Evidence/tests.log` |
| 外部端点单独测试 | `HOTELWIFI_LIVE_READONLY=1 swift test --skip-build --filter LiveReadOnlyTests`，1 项通过 | 工程 `Evidence/live-readonly-tests.log` |
| `Scripts/build.sh` | release 构建通过，生成 `.app` 与 ZIP | 工程 `Evidence/build-release.log` |
| `Scripts/verify-package.sh` | arm64、部署版本、Info.plist、辅助服务位置、独立 GUI/CLI 文件、CLI 入口及代码封印通过 | 工程 `Evidence/package-validation.log` |
| 临时签名权限门禁 | CLI `restore --json` 返回 69，辅助进程直接启动返回 78，均明确拒绝特权操作 | 工程 `Evidence/guarded-execution.json` |

默认测试仅使用模拟网络配置、私有临时文件及本机回环 TCP；不会修改开发机 WiFi，不访问外部测试端点。跳过项是必须通过环境变量显式启用的外部只读测试；其单独通过不增加默认套件的测试数量。

故障注入覆盖准备/登记时磁盘失败、写入后日志失败、权限撤销、日志损坏、字段冲突、预算耗尽、同时运行、睡眠与辅助服务重建。强杀测试启动独立子进程，持久保存并写入**模拟字段**，发送 SIGKILL，再启动另一个进程恢复；重复恢复也通过。这验证共用恢复状态机与持久性，不验证真实 launchd/root 服务的部署和恢复。

本机回环 HTTP 测试返回 200 后只发送部分正文并超时；结果被计为失败，已从 URLSession 指标补记 HTTP 状态和实际接收字节，不将收到响应头算作完整成功。各需求对应测试见 [验收场景映射](ACCEPTANCE.md)。

## 只读实机结果

使用发布版 `hotelwifi`、原生系统网络路径和默认端点运行；每行的计数包含基线与最终确认。

| 命令 | 完整请求 | 计入预算的接收量 | 配置写入 | 最终应用验证 |
|---|---:|---:|---|---|
| `diagnose` | 12 / 12 | 42,240 字节 | 无 | 通过 |
| `optimize --dry-run` | 12 / 12 | 42,240 字节 | 无 | 通过 |
| `monitor --once` | 4 / 4 | 154 字节 | 无 | 通过 |
| `report --json` | 成功读取上一条 4 / 4 的历史 | 不新增请求 | 无 | 仅报告历史结果 |

接收量采用回调与系统传输指标中较保守的观测值，可能含传输开销，不是固定对象正文大小。另行只读 curl 测试验证 Apple 与 Google 对象；其结果没有计入系统路径成功次数。

测试前后 `/Library/Preferences/SystemConfiguration/preferences.plist` 的 SHA-256 完全一致。该校验只证明观察的文件没有变化；没有据此宣称所有系统状态均未变化。汇总保存在工程 `Evidence/read-only-summary.json`。本次实机环境不等同于已完成酒店门户、企业代理或 VPN 环境验收。

能力检测返回 16 项。本机未授予 SSID/BSSID 读取权限时仍可完成上述诊断；helper 与 configurationWrite 均报告 unavailable。没有注册特权服务、获取 WiFi 密码、切换网络或开关 WiFi。

## 安装和界面验证边界

应用安装到 `~/Applications/HotelWiFi.app`，最终产物与安装副本的可执行文件校验一致，代码封印有效，启动后进程持续存在。安装检查记录于工程 `Evidence/install-validation.json`。

原生界面自动化服务 SkyComputerUseService 在读取该应用时崩溃，工具返回 `native pipe closed before response`；HotelWiFi 进程仍在运行。**未取得界面截图或完成按钮点击验收**，不能据进程启动宣称首次授权、菜单栏和全部交互已通过视觉验收。

## 实际支持范围与剩余验证

当前仅实现 DNS.ServerAddresses 与 Proxies.ProxyAutoDiscoveryEnable 两类受控配置执行器；它们需要独立授权、可确认的网络身份、非受管理环境、重复证据与已接管的恢复服务。没有可用恢复服务时保持只读。

以下是明确未开放的功能，不是已实现能力的成功占位：自动重连、切换已保存 SSID、DHCP 续租、AP 锁定。重连和候选网络偏好独立保存，但当前执行器不执行这些操作。

尚需验证或配置的项目：

- 自有 Developer ID Application 签名、SMAppService 注册与系统批准、XPC 调用者身份拒绝测试、正式分发公证。本机没有可用于本项目的 Developer ID 签名身份。
- 隔离网络上的真实 DNS/自动代理实验、修改收益判断、进程失联/辅助服务重启/系统重启后的真实恢复、用户改值冲突、离开酒店后的字段清理以及带活动事务的卸载。测试流程见 [真实写入测试](REAL_WRITE_TESTS.md)。
- 实机睡眠唤醒、长时间监控、门户登录、受管理配置、企业 VPN/分流 DNS、低数据及计费连接；目前只具备相应门禁与模拟覆盖，未宣称这些场景已实机通过。
- 手动 5 MB 测试对象功能未进行外网实测；默认优化不执行它。
- macOS 14 运行验收与其他硬件型号；本次仅生成并验证 arm64 产物。
- 原生界面的视觉与交互验收。

因此，本次可直接使用的是本机诊断、只读比较、历史与报告；包含有效配置修改及离网清理的最终用户路径尚待上述真实写入验证，不标记为完整通过。
