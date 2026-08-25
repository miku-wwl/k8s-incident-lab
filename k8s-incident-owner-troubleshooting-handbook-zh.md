# Kubernetes Incident Lab —— 事件操作与排障手册（Owner / 自学版）

> **适用对象：** Owner / 教练 / 自学复盘
> **是否包含剧透：** 是
> **重要：** 不要把本文件放入 Learner Bundle。
>
> 本手册用于说明如何启动实验室、激活每个 Incident、复现故障、调查问题、确认根因以及恢复环境。

---

# 1. 这套实验室到底训练什么

这不是“记 8 个 Kubernetes Bug”。

真正训练的是：

```text
观察症状
   ↓
判断影响范围
   ↓
建立假设
   ↓
找证据
   ↓
反证假设
   ↓
确认根因
   ↓
缓解
   ↓
从客户路径确认恢复
```

8 个 Incident 覆盖不同的 SRE / Kubernetes 故障域：

| Incident | 主要故障域 | 核心能力 |
|---|---|---|
| INC-01 | 发布回归 | 变更关联 + 下游超时 |
| INC-02 | 容量 / 自动扩缩容 | 错误的扩容信号 |
| INC-03 | 调度 / 维护 | Drain + Placement + PDB |
| INC-04 | 共享依赖 | Blast Radius + 依赖分析 |
| INC-05 | Service 数据面 | Service / EndpointSlice / targetPort |
| INC-06 | 异步处理 | Queue Backlog + KEDA + 吞吐 |
| INC-07 | 有状态工作负载 | PVC / 文件系统 / 权限 |
| INC-08 | 集群共享基础设施 | DNS 容量 + Throttling |

最重要的认知：

```text
Kubernetes 对象健康
        ≠
客户路径健康
```

Pod 可以是 `Running`。

Deployment 可以是 `Available`。

PVC 可以是 `Bound`。

CoreDNS Pod 可以是 `Ready`。

但客户仍然可能已经失败。

---

# 2. 实验室统一生命周期

```text
Healthy Baseline
      ↓
激活 Incident
      ↓
确认症状已复现
      ↓
调查
      ↓
形成 Root Cause 假设
      ↓
交叉验证
      ↓
恢复
      ↓
验证 Baseline
```

---

# 3. 启动实验室

## 3.1 创建 kind 集群

在仓库根目录：

```powershell
.\scripts\Start-Lab.ps1 -CreateKindCluster
```

标准拓扑必须是：

```text
1 control-plane
3 workers
```

总共：

```text
4 nodes
```

---

## 3.2 验证健康 Baseline

```powershell
.\scripts\Test-Lab.ps1 -Context kind-incident-lab
```

预期：

```text
PASS
```

不要从一个已经不健康的 Baseline 开始练 Incident。

---

## 3.3 打开 Grafana / Prometheus

```powershell
.\scripts\Open-Dashboards.ps1 -Context kind-incident-lab
```

通常：

```text
Grafana:
http://localhost:3000

Prometheus:
http://localhost:9090
```

Dashboard 用于：

```text
确认症状
观察趋势
做时间关联
```

但不要只靠 Dashboard 下 Root Cause 结论。

---

# 4. 每个 Incident 的通用操作

## 激活场景

例如 INC-01：

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

---

## Owner 确认故障是否注入成功

```powershell
.\scenario-builder\Test-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

> `Test-Scenario.ps1` 是 Owner / 实验设计者使用的验证工具。
>
> 学员排障时不应该把它当作主要调查工具，因为它可能暴露“故障是否已经达到预期状态”。

---

## Reset 当前场景

```powershell
.\scenario-builder\Reset-Scenario.ps1 `
  -Context kind-incident-lab
```

然后：

```powershell
.\scripts\Test-Lab.ps1 `
  -Context kind-incident-lab
```

必须重新回到：

```text
PASS
```

---

# 5. 通用 SRE 排障框架

## 第 1 步：客户到底坏了什么

先明确：

```text
5xx？
Latency？
写失败？
队列延迟？
DNS 超时？
部分请求失败？
```

不要一上来就看 Pod。

---

## 第 2 步：影响范围有多大

问：

```text
一个 Pod？
一个 Deployment？
一个 Service？
多个 Service？
一个 Node？
整个 Cluster？
```

Blast Radius 往往直接帮助你缩小故障域。

---

## 第 3 步：最近发生了什么变化

常见变更：

```text
Deployment rollout
配置变化
Node maintenance
Autoscaling 配置
Storage maintenance
共享基础设施 rollout
```

---

## 第 4 步：看 Kubernetes 状态

常用命令：

```powershell
kubectl --context kind-incident-lab -n incident-lab get pods -o wide
```

```powershell
kubectl --context kind-incident-lab -n incident-lab get deploy
```

```powershell
kubectl --context kind-incident-lab -n incident-lab get svc
```

```powershell
kubectl --context kind-incident-lab -n incident-lab get endpointslice
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get events --sort-by=.lastTimestamp
```

---

## 第 5 步：看 Metrics

不要只问“CPU 高不高”。

要问：

```text
这个 Metric 能不能解释客户症状？
```

常见指标：

```text
CPU
Latency
5xx
Queue Depth
Oldest Message Age
DNS Latency
DNS Timeout
Replica Count
```

---

## 第 6 步：看 Logs / Events

例如：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/gateway --tail=100
```

或：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe pod <pod-name>
```

---

## 第 7 步：建立精确假设

差的假设：

```text
Kubernetes 坏了。
```

好的假设：

```text
Gateway 2.0.0 把下游超时设置得比正常依赖链延迟还低。
```

---

## 第 8 步：找第二个证据交叉验证

例如：

```text
release change
+
timeout logs
+
downstream service healthy
```

这样才算比较完整的 Root Cause 证据链。

---

# 6. INC-01 —— 发布后 5xx 暴涨

## 6.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

确认注入：

```powershell
.\scenario-builder\Test-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

---

## 6.2 典型症状

```text
Gateway Pods: Running
Gateway Deployment: Available

但是：

5xx ↑
p95 ↑
成功率 ↓
```

这就是：

```text
Deployment Available
        ≠
Application Healthy
```

---

## 6.3 先看最近变更

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area changes
```

再看：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab rollout history deployment/gateway
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deployment/gateway -o yaml
```

你会发现：

```text
Gateway 1.x
    ↓
Gateway 2.0.0
```

---

## 6.4 查日志

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/gateway --tail=100
```

再看 Catalog：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/catalog --tail=100
```

再看 Identity：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/identity --tail=100
```

关键是：

```text
Gateway 出现 downstream timeout
但 Catalog / Identity 本身仍然健康
```

---

## 6.5 根因

新版 Gateway 的 downstream timeout 被调到大约：

```text
30ms
```

而正常依赖链大约：

```text
Gateway
  ↓
Catalog ~15ms
  ↓
Identity ~40ms
```

总耗时明显可能超过 30ms。

因此：

```text
configured timeout
<
normal dependency latency
```

Gateway 提前放弃了本来可以成功的请求。

---

## 6.6 这个 Incident 训练什么

不要因为：

```text
事故发生前刚好有 Deployment
```

就直接说：

```text
Deployment 是 Root Cause
```

要完成证据链：

```text
release change
+
timeout logs
+
downstream healthy
```

---

# 7. INC-02 —— CPU 不高，但 Gateway 已经容量爆炸

## 7.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-02 `
  -Context kind-incident-lab
```

---

## 7.2 症状

```text
Traffic ↑
Latency ↑
503 ↑

但 CPU 不算特别高
HPA 也没明显扩容
```

陷阱：

```text
CPU 不高
≠
应用容量足够
```

---

## 7.3 看 Capacity

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area capacity
```

```powershell
kubectl --context kind-incident-lab -n incident-lab top pods
```

```powershell
kubectl --context kind-incident-lab -n incident-lab get hpa
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe hpa gateway
```

再看：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deployment/gateway -o yaml
```

---

## 7.4 关键配置

Gateway 有很小的并发上限：

```text
MAX_INFLIGHT = 2
```

但 HPA 看的是：

```text
CPU utilization
```

例如：

```text
CPU request = 500m
HPA target = 65%
```

---

## 7.5 日志

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/gateway --tail=100
```

会出现：

```text
request_rejected
reason=concurrency_limit
```

---

## 7.6 根因

真正先被打满的是：

```text
应用并发槽位
```

不是 CPU。

因此：

```text
真实瓶颈 = concurrency
扩容信号 = CPU
```

信号选错。

---

## 7.7 核心认知

Autoscaling 的关键问题不是：

```text
我会不会配 HPA？
```

而是：

```text
HPA 看的是不是“最先饱和的资源”？
```

---

# 8. INC-03 —— Node Drain 后服务不可用

## 8.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-03 `
  -Context kind-incident-lab
```

---

## 8.2 症状

Node maintenance 后：

```text
Gateway available replicas ↓
替代 Pod Pending
```

---

## 8.3 看 Node

```powershell
kubectl --context kind-incident-lab get nodes
```

找：

```text
SchedulingDisabled
```

---

## 8.4 看 Pod 放置

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods -o wide
```

然后：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe pod <pending-gateway-pod>
```

重点看：

```text
Events
```

通常会看到：

```text
FailedScheduling
```

---

## 8.5 看 placement constraint

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deployment/gateway -o yaml
```

例如：

```text
nodeSelector:
training.example.com/tier=primary
```

---

## 8.6 看 PDB

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pdb/gateway -o yaml
```

这个场景的关键是三者组合：

```text
placement constraint
+
weak PDB
+
node drain
```

---

## 8.7 根因

```text
Gateway 只能跑 primary worker
        ↓
primary worker 被 drain / cordon
        ↓
旧 Pod 被驱逐
        ↓
新 Pod 尝试调度
        ↓
找不到符合条件的 Node
        ↓
Pending
```

不是 Drain 一条命令本身的问题。

---

# 9. INC-04 —— 多个服务同时坏，真正问题在共享 Identity

## 9.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-04 `
  -Context kind-incident-lab
```

---

## 9.2 症状

多个服务一起失败：

```text
Gateway ❌
Catalog ❌
Orders  ❌
```

但很多 Pod 仍然：

```text
Running
```

---

## 9.3 第一反应

不要想：

```text
是不是三个服务同时各自有 Bug？
```

先想：

```text
它们有没有共同依赖？
```

---

## 9.4 看上游日志

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/gateway --tail=100
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/catalog --tail=100
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/orders --tail=100
```

---

## 9.5 看 Identity

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/identity --tail=100
```

会找到：

```text
request_rejected
reason=concurrency_limit
```

---

## 9.6 根因

多个服务共享 Identity：

```text
Gateway ----\
Catalog -----+----> Identity
Orders ------/
```

Identity 达到并发容量上限。

于是：

```text
shared dependency saturation
        ↓
多个上游一起退化
```

---

## 9.7 核心认知

Blast Radius 本身就是线索。

如果：

```text
A 坏
B 坏
C 坏
```

优先想：

```text
共享依赖
共享 Node
共享 DNS
共享存储
共享网络路径
```

---

# 10. INC-05 —— Pod Ready，但 Service 数据面一半失败

## 10.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-05 `
  -Context kind-incident-lab
```

---

## 10.2 症状

表面看起来：

```text
Deployment Ready
Pods Running
Restart = 0
EndpointSlice 存在
```

但真实请求：

```text
200
503
200
timeout
200
503
```

---

## 10.3 调查 Service Path

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area service-path
```

看 Service：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get svc gateway -o yaml
```

看 EndpointSlice：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get endpointslice `
  -l kubernetes.io/service-name=gateway -o yaml
```

看 Gateway Pods：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods `
  -l app.kubernetes.io/name=gateway -o wide
```

---

## 10.4 对比所有端口

必须一起看：

```text
Application listening port
Readiness probe port
Container named port
Service targetPort
EndpointSlice port
```

---

## 10.5 根因

新 rollout 里应用监听：

```text
8081
```

Readiness 也检查：

```text
8081
```

所以：

```text
Pod Ready ✅
```

但 Service 的：

```text
targetPort: http
```

映射到：

```text
container named port = 8080
```

于是：

```text
Readiness:
8081 → 成功

真实 Service 流量:
8080 → 失败
```

---

## 10.6 核心认知

排查 Service 问题时要完整走：

```text
Service
  ↓
selector
  ↓
EndpointSlice
  ↓
Pod
  ↓
targetPort
  ↓
应用真实监听端口
```

不能看到 EndpointSlice 非空就结束。

---

# 11. INC-06 —— API 202 正常，但 Queue 越积越多

## 11.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-06 `
  -Context kind-incident-lab
```

---

## 11.2 症状

同步 API：

```text
POST /orders
→ 202 Accepted
```

但异步完成变差：

```text
queue_depth ↑
oldest_message_age ↑
```

---

## 11.3 看 Queue

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area queue
```

---

## 11.4 看 Worker

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deployment/worker
```

---

## 11.5 看 KEDA

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get scaledobject worker -o yaml
```

再看 HPA：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get hpa
```

---

## 11.6 根因

场景让 KEDA 几乎无法有效扩容。

概念上类似：

```text
maxReplicaCount = 2
listLength = 极高
```

同时 Producer 生成速度大于两个 Worker 的处理速度。

例如：

```text
Producer = 20 msg/s

Worker = 4 msg/s each

2 workers = 8 msg/s
```

于是：

```text
Backlog growth
=
20 - 8
=
12 msg/s
```

自然越积越多。

---

## 11.7 核心认知

```text
202 Accepted
≠
业务真正完成
```

异步系统必须监控：

```text
Queue Depth
Oldest Message Age
Processing Throughput
Retry / Failure Rate
```

---

# 12. INC-07 —— PVC Bound，但写数据库失败

## 12.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-07 `
  -Context kind-incident-lab
```

---

## 12.2 症状

```text
Storage Pod: Ready
PVC: Bound
CPU: 正常

Read: 成功
Write: 失败
```

---

## 12.3 看 Storage Evidence

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area storage
```

---

## 12.4 看 StatefulSet / PVC

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get sts,pvc
```

不要看到：

```text
PVC Bound
```

就宣布 Storage 健康。

---

## 12.5 看最近 Job

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get jobs
```

找最近完成的 maintenance Job。

---

## 12.6 看应用日志

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs statefulset/storage -c app --tail=100
```

重点找：

```text
permission
write failure
filesystem
```

---

## 12.7 用受限 Inspector 看文件系统

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab exec storage-inspector-0 -- `
  sh -c 'id; df -h /data; ls -ld /data; ls -la /data | head'
```

关注：

```text
ownership
permissions
mount
文件是否可写
```

---

## 12.8 根因

Maintenance 修改了 PVC 上的权限。

概念上：

```bash
chmod -R a-w /data
```

结果：

```text
Read ✅
Write ❌
```

PVC 仍然可以：

```text
Bound
```

因为“绑定成功”不代表“应用拥有正确的文件权限”。

---

## 12.9 核心认知

不要：

```text
Storage 出问题
↓
删 PVC
```

有状态事故必须优先考虑：

```text
RTO
RPO
数据保护
权限
Mount
Filesystem state
```

否则可能把：

```text
Availability Incident
```

升级成：

```text
Data Loss Incident
```

---

# 13. INC-08 —— CoreDNS 没死，但整个集群开始随机超时

## 13.1 启动

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-08 `
  -Context kind-incident-lab
```

这个场景通常要比其他场景观察更久一点。

---

## 13.2 症状

多个看起来没直接关系的服务同时出现间歇问题：

```text
Gateway 偶发 timeout
Catalog 偶发 timeout
Orders 偶发 timeout
Storage 偶发 timeout
```

但 Pod 大部分仍然：

```text
Running / Ready
```

---

## 13.3 第一反应：共享基础设施

优先考虑：

```text
DNS
CNI
Node
Service routing
shared proxy
shared dependency
```

---

## 13.4 收集 DNS Evidence

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area dns
```

关注：

```text
CoreDNS Pods
CoreDNS Service
EndpointSlice
CoreDNS CPU
DNS latency
DNS timeout
真实 DNS lookup
CoreDNS logs
跨服务错误率
```

---

## 13.5 看 CoreDNS

```powershell
kubectl --context kind-incident-lab `
  -n kube-system get pods -l k8s-app=kube-dns -o wide
```

```powershell
kubectl --context kind-incident-lab `
  -n kube-system top pods -l k8s-app=kube-dns
```

```powershell
kubectl --context kind-incident-lab `
  -n kube-system logs deployment/coredns --tail=100
```

---

## 13.6 根因

场景同时造成：

```text
CoreDNS 容量下降
+
DNS 查询压力上升
```

形成：

```text
DNS load ↑
    ↓
CoreDNS CPU limit
    ↓
throttling
    ↓
DNS response 变慢
    ↓
client timeout
    ↓
retry
    ↓
更多 DNS traffic
    ↓
更严重 throttling
```

这就是：

```text
retry amplification
```

---

## 13.7 核心认知

```text
CoreDNS Ready
≠
DNS service healthy
```

共享基础设施一旦容量不足，Blast Radius 会非常大。

---

# 14. 推荐学习顺序

不要把这 8 个场景看成 8 个独立 Bug。

它们是递进的：

```text
INC-01
发布回归
   ↓
INC-02
应用容量
   ↓
INC-03
调度 / 维护
   ↓
INC-04
分布式依赖
   ↓
INC-05
Kubernetes Service 数据面
   ↓
INC-06
异步系统
   ↓
INC-07
有状态系统
   ↓
INC-08
集群级共享基础设施
```

---

# 15. 推荐练习方式

第一次跑某个 Incident 时：

```text
不要先看本手册对应的 Root Cause。
```

正确方法：

1. 启动 Incident。
2. 只看 Learner Incident Brief。
3. 用 kubectl / Grafana / Prometheus / Learner Evidence 调查。
4. 写下你的第一个假设。
5. 找支持证据。
6. 再找能反驳它的证据。
7. 最后再回来看 Owner 手册。

建议记录：

```text
Customer Symptom:

Blast Radius:

Recent Changes:

Evidence #1:

Evidence #2:

Current Hypothesis:

Alternative Hypothesis:

Next Highest-Information Command:

Confirmed Root Cause:

Mitigation:

Recovery Validation:
```

---

# 16. 常用命令速查

## Pods

```powershell
kubectl --context kind-incident-lab -n incident-lab get pods -o wide
```

## Deployments

```powershell
kubectl --context kind-incident-lab -n incident-lab get deploy
```

## Events

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get events --sort-by=.lastTimestamp
```

## Pod Describe

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe pod <pod-name>
```

## Deployment Logs

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/<deployment-name> --tail=100
```

## Service

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get svc <service-name> -o yaml
```

## EndpointSlice

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get endpointslice -o wide
```

## HPA

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get hpa
```

## Pod Metrics

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab top pods
```

## Nodes

```powershell
kubectl --context kind-incident-lab get nodes
```

## PVC

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pvc
```

## Jobs

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get jobs
```

## KEDA

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get scaledobject
```

---

# 17. 每次 Incident 结束后的恢复检查

先：

```powershell
.\scenario-builder\Reset-Scenario.ps1 `
  -Context kind-incident-lab
```

再：

```powershell
.\scripts\Test-Lab.ps1 `
  -Context kind-incident-lab
```

确认：

```text
Baseline PASS
No active scenario
Expected replicas healthy
Customer paths healthy
No unexpected Pending Pods
No residual maintenance state
```

上一场没有恢复干净，不要开始下一场。

---

# 18. 八个 Incident 最核心的一句话

## INC-01

```text
Kubernetes 健康，不代表新版本应用健康。
```

## INC-02

```text
自动扩容必须使用真正代表瓶颈的信号。
```

## INC-03

```text
维护安全取决于调度约束、PDB 和操作方式的组合。
```

## INC-04

```text
大范围故障通常应该优先怀疑共享依赖。
```

## INC-05

```text
Readiness 成功，不代表 Service 真实数据路径可用。
```

## INC-06

```text
HTTP 接受请求，不代表异步业务真正完成。
```

## INC-07

```text
PVC Bound，不代表应用拥有正确的读写能力。
```

## INC-08

```text
共享基础设施可以保持 Ready，同时已经严重超载。
```

---

# 19. 最终 SRE 思维

不要问：

```text
哪个 Kubernetes 对象红了？
```

应该问：

```text
什么证据最能解释客户故障？

下一条信息增益最高的命令是什么？
```

真正的目标是形成：

```text
Observe
  ↓
Scope
  ↓
Hypothesize
  ↓
Gather Evidence
  ↓
Falsify
  ↓
Confirm Root Cause
  ↓
Mitigate
  ↓
Validate Customer Recovery
```
