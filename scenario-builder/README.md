# 场景构建器操作说明 — 私有

此目录属于场景构建器（Scenario Builder）角色。不要把该目录、相关终端历史、`.scenario-state/` 或会话上下文暴露给学员或教练。只能通过 `New-LearnerBundle.ps1` 分发仓库外学员安全包。

所有场景都从同一个健康基线开始，并使用中性的运行时变更描述。同一时间只能激活一个场景。

| 事件 | 场景构建器故障机制 | 预期运行时证据 | 主要恢复方式 |
|---|---|---|---|
| INC-01 | Gateway 新版本使用了低于正常下游延迟的客户端超时 | 发布修订号、镜像标签、依赖超时、5xx 和 p95 | 回滚 gateway 版本 |
| INC-02 | 具有代表性的同步需求超过单 Pod 并发能力，同时过大的 CPU 资源请求让 HPA 使用了错误信号 | CPU 利用率百分比仍较低/中等、并发拒绝、HPA 反应不足 | 降低需求或扩展真正有效的容量 |
| INC-03 | 工作负载只能调度到维护目标，而 PDB 允许全部 Pods 被驱逐 | 已排空节点、处于 Pending 的 gateway Pods、PDB 和节点选择器 | 停止维护/取消封锁，并恢复调度位置/PDB |
| INC-04 | 共享 identity 依赖被突发需求压满 | 多个调用方失败、identity 并发拒绝、调用方看起来正常 | 移除共享压力或增加共享容量 |
| INC-05 | 渐进式 Gateway revision 的就绪端口与 Service 数据端口不一致 | 两组 Deployment 和 EndpointSlice 均显示 Ready，客户请求部分成功、部分失败 | 移除异常 revision 或恢复端口契约 |
| INC-06 | Redis 队列到达速率超过 worker 吞吐量，而 KEDA 触发器无法有效扩容 | 队列深度/消息年龄持续增长、worker 仍在运行、伸缩器受限 | 恢复伸缩能力并清空积压 |
| INC-07 | 已完成的存储维护 Job 改变 PVC 文件系统写权限 | PVC Bound、StatefulSet Ready、读成功但写失败、文件系统证据异常 | 恢复预期所有权/权限，并验证持久化读写和数据状态 |
| INC-08 | Resolver CPU 容量 rollout 与高基数查询压力共同造成 DNS throttling 和重试放大 | CoreDNS Ready、查询量/延迟/超时上升、多条跨服务路径间歇退化 | 降低异常查询压力并恢复安全的 Resolver 容量 |

重置脚本会先执行场景专属清理，再重新应用声明式基线。INC-08 的 CoreDNS 原始资源配置只保存在 Builder 本地、被 Git 忽略的状态文件中，并在 reset 时精确恢复。所有场景脚本都拒绝非 kind 上下文、未标记的实验命名空间和不满足 1+3 拓扑的集群。

调查结束后，使用 `evaluator/New-EvaluationPackage.ps1` 生成仓库外评估包。不要在场景仍激活或学员尚未提交 RCA 时揭示 `evaluator/rubrics/`。
