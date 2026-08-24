# 架构与隔离模型

## 运行时拓扑

```text
traffic-gateway -> gateway -> catalog -> identity
traffic-catalog -----------> catalog -> identity
traffic-orders  -----------> orders  -> identity
                                  |
                                  v
                                Redis <- worker replicas（KEDA）

traffic-storage -----------> storage StatefulSet -> SQLite on PVC
traffic-storage-read ------> storage read path ----> same PVC

Prometheus <- 带抓取注解的应用/流量 Pods + kube-state-metrics
Grafana    <- Prometheus
```

就绪探针只用于确认本地进程健康，不代表下游客户路径健康。因此，响应者必须区分 Pod 健康、Service 健康和客户健康。

## 隔离边界

仓库和分发产物分成三个信任区域：

| 区域 | 材料 | 谁可以查看？ |
|---|---|---|
| 学员安全区 | `New-LearnerBundle.ps1` 生成的仓库外安全包、Kubernetes 运行时状态、日志、指标、事件、发布历史 | 学员和教练 |
| Owner 控制面 | 完整 Git checkout、`scenario-builder/`、应用源代码、仓库历史/差异 | 仅场景构建器/Owner |
| Evaluator 私有区 | `evaluator/rubrics/` 和调查关闭后生成的仓库外评估包 | 仅 Owner 和 Evaluator |

教练必须运行在全新的会话中，因为提示词指令无法清除另一个会话已经看过的上下文。学员和教练都不能获得完整 checkout；这样可以在文件分发层面阻断源代码、Builder 脚本和 Ground Truth，而不只是依赖行为约定。

## 场景生命周期不变量

每次运行都必须经过以下证据门：

```text
声明式基线
  -> readiness 与真实请求检查
  -> 一项由 Builder 管理的变更
  -> 症状观察
  -> 学员作出缓解决定
  -> 场景构建器重置
  -> 独立基线验证
  -> 学员提交 RCA
  -> 生成仓库外 Evaluator 包
  -> Ground Truth 对照和评分
```

实验命名空间中的 `scenario-state` 用于阻止多个注入同时运行。它只包含事件 ID 和开始时间，不包含故障机制。恢复所需的私有原始状态保存在 Builder 本地且被 Git 忽略的 `.scenario-state/` 中，不会进入学员安全包。

## 可观测性范围

Prometheus 只发现 `incident-lab` 中带抓取注解的 Pods，并抓取 kube-state-metrics 和 CoreDNS。告警使用症状命名：请求错误、延迟、跨服务调用失败、处理延迟和有状态操作延迟。仪表盘展示服务级和工作负载级信号，但不会指出根因。

Kubernetes 事件和发布历史是操作变更的权威运行时证据。应用日志采用结构化 JSON，记录请求拒绝、依赖失败、队列失败和存储失败事件。

## 本地集群假设

- 共享拓扑固定为四个节点：一个控制平面节点和三个可调度工作节点。
- Redis 和 SQLite PVC 需要默认的动态 StorageClass。
- 队列伸缩场景需要 KEDA。
- `kubectl top` 和 CPU HPA 需要 metrics-server。
- DNS/网络场景要求 CoreDNS 由 `kube-system/deployment/coredns` 管理并暴露运行时指标。

提供的 kind 路径满足节点拓扑要求。设置脚本会验证工作负载就绪状态；如果缺少 StorageClass 或附加组件，设置过程会明确失败，不会悄悄启动一个损坏的基线。
