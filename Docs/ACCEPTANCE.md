# 验收场景映射

表中“通过”只指对应自动化规则或模拟网络适配层，不代表特权服务已在真实 WiFi 上完成验收。真实只读与真实写入单独见 `VALIDATION.md`。

| 用户场景 | 自动化证据 |
|---|---|
| ping 丢包 85%，HTTPS 20 次完整成功 | `test85PercentICMPLossCannotOverride20SuccessfulHTTPSRequests`；ICMP 不进入修改决策 |
| RSSI 强，应用持续失败 | `testStrongSignalDoesNotMakeFailedApplicationsHealthy` |
| CCA 72%→8%，应用无改善 | `testCCADropWithoutApplicationImprovementIsNotAWinner` |
| 单次 Tx Rate 为零 | `testSingleZeroTransmitRateDoesNotTriggerReconnect` |
| HTTP 200，正文超时 | `testHTTP200WithBodyTimeoutIsFailure`，真实回环 TCP 半响应；另有 curl 退出码测试 |
| curl 直连成功，系统路径失败 | `testDirectCurlSuccessDoesNotCountAsSystemConnectivity` |
| DNS 仅几毫秒差异 | `testMillisecondDNSDifferencesKeepOriginal` |
| IPv6 正常，无 IPv4 | `testIPv6OnlyHealthyConnectionRejectsDHCPRepair` |
| 速度快但失败更多 | `testFasterButLessReliableIsRestoredImmediately`，共用正式 ExperimentRunner |
| 只一次变快 | `testLostRepeatBenefitRestoresAfterSecondExperiment` |
| 无法恢复历史最佳 AP | `testAPRequestIsObservedSeparatelyFromAssociationAndNeverLocked`；无持续锁定接口，实际 AP 不匹配不宣称成功 |
| 主应用被强制退出 | `testSIGKILLThenSeparateGuardianRestoresDurableSimulation`；独立进程、真实持久文件、模拟配置后端 |
| 用户中途改 DNS | `testUserDNSModificationWinsAndConflictIsRecorded`、`testExternalChangeAtCASCannotBeOverwritten` |
| 用户关闭 WiFi | `testUserTurnsOffWiFiNoActionTurnsItBackOn`；后端没有电源操作接口 |
| 酒店切公司 | `testLeavingHotelCleansFieldWithoutRestoringHotelIP` |
| 同名 SSID 的其他酒店 | `testSameSSIDIsNotEnoughToReuseAnotherHotelIdentity`；历史不重放、Link 重建结束会话 |
| 权限被拒绝/guardian 失效 | `testDeniedPermissionsAndUnavailableGuardianNeverWrite` |
| 测试端点故障 | `testSingleEndpointFailureIsNotWholeNetworkFailure` |
| 流量/时间预算 | `testActualReceivedBytesEnforceCapWithoutContentLength`、`testBudgetExhaustedDuringCandidateStillRollsBack`、`testExpiredArmedTransactionCannotApply` |
| 连续优化/同时 CLI | `testOnlyOneTransactionAcrossSimultaneousClients`、`testPrivateAtomicStorageRejectsSymlinksAndConcurrentLock` |
| 健康连接无明确收益 | 分层规则拒绝小改善；实机只读运行返回无需修改，见验证记录 |
| 输出变化/字段缺失 | `testReusedOrMissingStagesAreNilNotZero`、curl JSON 严格解析、能力 unknown |
| 权限撤销 | `testPermissionRevocationWaitsAndRetriesIdempotently` |
| 磁盘失败 | `testPrepareOrArmDiskFailurePreventsSystemWrite`、`testCrashBetweenSystemWriteAndApplyLogRemainsRecoverable`、`testDiskFailureDuringRollbackStillRestoresKnownOriginal` |
| 日志损坏 | `testActualJournalRejectsCorruptionAndRoundTripsAbsentFields` |
| 系统睡眠 | `testSleepDoesNotTurnMissedHeartbeatIntoNetworkFailure` |
| helper 重启 | `testApplicationCrashAfterApplyIsRecoveredByNewGuardian`、独立进程恢复测试 |
| 字段恢复冲突 | `testUserDNSModificationWinsAndConflictIsRecorded`；不把 conflict 标成“恢复完成” |
| 参数注入/错误 URL | `testCurlArgvIgnoresCurlrcAndExplicitlyBypassesInheritedProxyOnlyForDiagnostic`、`testEndpointValidationRejectsCredentialsAndNonHTTPS` |
| 报告隐私 | `testExportRemovesNetworkIdentityAndServiceName`、`testIdentityHashNeedsLocalSecretAndKeepsNoRawSSID` |

默认测试包括本地回环 TCP、模拟配置和临时目录；不会访问外部 HTTPS 端点。`LiveReadOnlyTests` 只有在 `HOTELWIFI_LIVE_READONLY=1` 时才运行，且仅执行受控 GET 请求。

1.1 新增 `LinkRecoveryTests`，覆盖本机签名固定、老策略兼容、DHCP/IPv6 门禁、候选授权、ARM/磁盘失败、关联中崩溃、外部切网/关 WiFi、同名 SSID 的不同 AP、重启未连接、AP 观察与锁定区别、提交后保留可用连接、双窗口、VPN/配置冲突、加密恢复材料、三次上限及流量样本。
