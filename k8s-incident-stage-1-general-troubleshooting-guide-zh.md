# Kubernetes 事故定位第一阶段学习指南（CKAD 起点）

> 适用对象：已经具备 CKAD 基础，但还没有系统做过 Kubernetes 生产事故定位的学习者
> 本阶段目标：先理解健康系统、证据层次和通用调查方法，再进入具体 Incident
> 是否包含场景答案：否
> 建议学习方式：一次只完成一小节；每完成一节，都要运行命令、解释结果并留下记录

---

## 1. 学完这一阶段，你应该会什么

完成本阶段后，你应该能够独立回答下面这些问题：

1. `Pod Running`、`Pod Ready`、`Deployment Available` 和“客户请求健康”有什么区别？
2. 一个请求从 Service 到 Pod，中间经过哪些 Kubernetes 对象？
3. 怎样判断故障影响的是一个 Pod、一个 Service、一个 Node，还是多个服务？
4. 怎样区分持续失败和间歇失败？
5. `get`、`describe`、Events、Logs 和 Metrics 分别能证明什么？
6. 怎样把事实、推断和未知项分开记录？
7. 怎样提出一个可以被证伪的假设？
8. 怎样选择“下一条信息增益最高的命令”？
9. 为什么恢复验证必须从客户路径开始？
10. 为什么一次事故练习必须从健康基线开始，并在结束后重新证明健康？

如果这些问题还不能用自己的话回答，就先不要急着进入八个故障场景。

---

## 2. 本仓库当前的端到端验证状态

在编写本指南前，已经在一个全新的专用 kind 集群上完成了真实端到端验证。

验证环境：

```text
kind:                   v0.32.0
Kubernetes server:      v1.36.1
kubectl client:         v1.36.1
拓扑:                   1 control-plane + 3 workers
KEDA:                   2.20.2
metrics-server:         0.9.0
Prometheus:             v3.5.0
Grafana:                12.1.1
```

本次实际通过的证据门：

```text
Repository validation                         PASS
Initial healthy baseline                      PASS
INC-01 ～ INC-08 pre-activation baseline      PASS
INC-01 ～ INC-08 activation                   PASS
INC-01 ～ INC-08 symptom reproduction         PASS
INC-01 ～ INC-08 learner runtime evidence     PASS
INC-01 ～ INC-08 reset and recovery           PASS
Final recovery baseline                       PASS
FullMatrix evidence document                  PASS
```

本次机器证据保存在仓库外：

```text
C:\Users\weila\AppData\Local\Temp\k8s-incident-lab-fullmatrix-20260831.json
```

这能证明实验室实现和八个场景当前可以完整运行，但不能证明学习者已经掌握事故定位。学习效果仍然要通过你自己的调查记录、假设、反证和恢复判断来证明。

### 2.1 本次启动中遇到的真实问题

第一次检查旧集群时，基线没有通过：

```text
storage-read: connection refused
```

继续调查发现：

- 旧集群已经连续运行约 6 天；
- 持续写流量使 SQLite 文件增长到约 1.6 GB；
- `storage-0` 的探针开始超时；
- Pod 在约 40 小时内被 liveness probe 重启 78 次；
- PVC 仍然是 `Bound`，Pod 也会在 `Running` 和不健康之间变化。

因此，这个环境不能被当作健康基线。实验室使用的是一次性专用 kind 集群，所以本次重建了集群，再重新验证。

新集群第一次安装时，还遇到了固定 digest 镜像冷拉取时间较长的问题。KEDA、Redis 和监控组件一度停留在：

```text
ContainerCreating
```

Events 显示的是：

```text
Pulling image ...
```

而不是调度失败、PVC 失败或配置错误。等镜像准备完成并重新执行声明式部署后，组件全部 Ready，基线通过。

这里最重要的学习点不是具体修复命令，而是调查纪律：

```text
先确认失败发生在哪一层
  ↓
读取 Events 证明当前状态
  ↓
判断状态是否仍在推进
  ↓
只处理已经被证据支持的问题
  ↓
重新运行完整健康门
```

---

## 3. CKAD 到事故定位，中间还缺什么

CKAD 主要训练你正确创建和操作 Kubernetes 工作负载。事故定位需要在这些知识之上增加“证据推理”。

| CKAD 常见能力 | 事故定位需要增加的能力 |
|---|---|
| 创建 Deployment | 判断期望状态与实际状态在哪里分叉 |
| 配置 readiness/liveness probe | 判断探针健康是否等于客户路径健康 |
| 创建 Service | 验证 selector、EndpointSlice、端口和实际监听是否一致 |
| 查看 Pod 日志 | 把日志与时间窗口、请求症状和其他证据关联起来 |
| 配置 requests/limits | 判断真正瓶颈是 CPU、并发、队列还是依赖 |
| 配置 HPA | 判断伸缩指标是否真正代表业务瓶颈 |
| 使用 PVC | 区分 PVC 绑定、文件系统可用和应用读写健康 |
| 处理调度约束 | 判断 Node、PDB、affinity 和容量怎样共同影响维护安全 |

CKAD 经常问：

```text
这个对象应该怎么配置？
```

事故定位更常问：

```text
客户到底坏了什么？
哪个运行时事实最能解释这个症状？
下一条命令能排除哪个假设？
```

---

## 4. 先理解这个实验室里的请求路径

这个实验室不是一组孤立的 Pod。它包含同步请求、共享依赖、异步队列、有状态存储和集群 DNS。

```text
traffic-gateway
      |
      v
   gateway ------> catalog ------> identity

traffic-catalog --> catalog ------> identity

traffic-orders ---> orders -------> identity
                         |
                         v
                       Redis <------ worker replicas (KEDA)

traffic-storage ------> storage StatefulSet ------> SQLite on PVC
traffic-storage-read -> storage read path --------> 同一个 PVC

Prometheus <--- 应用指标、流量指标、kube-state-metrics、CoreDNS
Grafana    <--- Prometheus
```

这个拓扑告诉我们：

- Gateway 自己正常，不代表 Catalog 或 Identity 正常；
- API 接受请求，不代表异步 Worker 已经处理完成；
- Storage Pod Ready，不代表 PVC 上的真实读写成功；
- 多个服务同时失败时，要考虑共享依赖、Node、DNS 或网络；
- 只查看一个 Pod，无法解释完整客户路径。

---

## 5. 事故定位必须掌握的 Kubernetes 基础模型

### 5.1 期望状态和观察状态

Kubernetes 控制器一直在比较：

```text
spec 中的期望状态
        与
status 中的观察状态
```

例如 Deployment：

```text
spec.replicas              期望副本数
status.readyReplicas       已通过 readiness 的副本数
status.availableReplicas   满足可用条件的副本数
status.updatedReplicas     已更新到新 PodTemplate 的副本数
```

调查时不要只看一个数字。下面两种状态代表不同问题：

```text
Desired=3, Ready=0
```

表示工作负载层已经明显异常。

```text
Desired=3, Ready=3，但客户仍然 503
```

表示需要继续调查 Service 数据路径、应用行为或下游依赖。

### 5.2 Pod 的几个不同概念

```text
Scheduled
  表示 Pod 已被分配给某个 Node。

Running
  表示至少一个容器已经启动；不保证应用可以服务客户。

Ready
  表示 readiness probe 当前成功；只证明探针配置检查的内容。

Restart Count
  表示容器曾被重启；必须结合时间和 previous logs 判断原因。
```

常见误区：

```text
STATUS=Running
```

不等于：

```text
客户请求成功
```

### 5.3 三类 Probe

```text
startupProbe
  应用是否已经完成启动；成功前可保护慢启动应用。

readinessProbe
  当前是否应该接收 Service 流量。

livenessProbe
  当前进程是否需要被 kubelet 重启。
```

探针只会执行清单中配置的检查。如果 readiness 只检查本地 `/health/ready`，它可能完全不知道下游依赖已经超时。

### 5.4 Service 和 EndpointSlice

Service 本身不会运行应用。它根据 selector 找到 Pod，并通过 EndpointSlice 保存可路由目标。

```text
Service selector
      ↓
matching Pods
      ↓
EndpointSlice addresses and ports
      ↓
Pod IP + target port
      ↓
application listener
```

因此调查 Service 路径时至少要比较：

```text
Service selector
Service port
Service targetPort
EndpointSlice addresses
EndpointSlice ready condition
Pod labels
container port / named port
应用真实监听端口
```

### 5.5 Node 和调度

Pod 处于 `Pending` 时，第一优先级通常不是看应用日志，因为容器可能根本没有启动。

先看：

```text
Pod 是否已经 Scheduled？
Scheduler Events 说了什么？
Node 是否 Ready / cordoned？
是否存在 nodeSelector、affinity、taint/toleration？
资源请求是否能被任何 Node 满足？
PDB 是否影响维护操作？
```

### 5.6 Logs、Events 和 Metrics 的区别

| 证据 | 主要回答什么 | 不能单独证明什么 |
|---|---|---|
| `kubectl get` | 当前对象状态 | 状态为什么形成 |
| `kubectl describe` | 对象配置、Conditions、相关 Events | 完整客户影响 |
| Kubernetes Events | 调度、拉取镜像、探针、挂载等控制面动作 | 长时间业务趋势 |
| 应用 Logs | 某个进程在某段时间内记录了什么 | 全局影响范围 |
| Metrics | 错误率、延迟、吞吐、资源等趋势 | 单个请求的完整因果链 |
| 客户路径探测 | 用户边界是否成功 | 内部根因 |

高质量调查通常会组合至少两种独立证据。

---

## 6. 健康不是一个布尔值，而是分层证据

可以把系统健康分成六层：

| 层次 | 核心问题 | 代表性证据 |
|---|---|---|
| 1. 集群访问 | API Server 和目标上下文是否可用？ | context、nodes、version |
| 2. 调度与进程 | Pod 是否被调度、容器是否启动？ | Pods、Conditions、Events |
| 3. Kubernetes 路由 | Service 是否有正确 Endpoint？ | Service、EndpointSlice |
| 4. 应用与依赖 | 应用是否能完成下游调用？ | Logs、依赖错误、延迟指标 |
| 5. 业务流程 | HTTP、队列、存储等完整流程是否完成？ | 客户探测、queue age、读写结果 |
| 6. 可观测性 | 用来判断健康的指标是否可信？ | Prometheus targets、采集时间 |

调查时从客户症状开始，但验证每个假设时要进入相应层次。

例如：

```text
客户看到间歇 503
  ↓
Deployment 3/3 Available
  ↓
不能停止调查
  ↓
继续看 EndpointSlice、每个目标、端口和下游日志
```

---

## 7. 每次调查都使用三个坐标轴

### 7.1 时间轴：什么时候开始坏

记录：

```text
最后一次确认健康的时间
第一次告警时间
最近发布或维护时间
第一次缓解动作时间
客户路径恢复时间
```

没有时间窗口的日志搜索通常会制造噪声。

### 7.2 空间轴：坏在哪里

逐步判断 Blast Radius：

```text
一个请求
一个 Pod
一组 Pod
一个 Service
一个 Node
一个可用区或故障域
多个服务
整个集群
```

### 7.3 系统层次：在哪一层坏

```text
客户边界
应用
依赖
Service 路由
Pod / Container
Node / Scheduling
Storage
DNS / Network
Control Plane
```

一个好的假设必须同时说明时间、范围和层次。

---

## 8. 标准事故定位循环

以后每个 Incident 都使用下面的循环：

```text
Observe
  ↓
Scope
  ↓
Check recent changes
  ↓
Form falsifiable hypotheses
  ↓
Gather evidence
  ↓
Falsify alternatives
  ↓
Choose a low-risk mitigation
  ↓
Validate customer recovery
  ↓
Complete RCA after recovery
```

### Step 1：先描述客户症状

不要先写“某个 Pod 有问题”。先描述用户看到的行为：

```text
5xx
timeout
latency
写失败
请求被接受但业务迟迟未完成
持续失败
间歇失败
```

### Step 2：确定影响范围

至少回答：

```text
哪些客户路径受影响？
哪些路径仍然成功？
是一个服务还是多个服务？
是否集中在一个 Pod 或一个 Node？
```

“仍然成功的路径”经常和失败路径一样有价值，因为它能帮助排除共享组件。

### Step 3：区分持续失败和间歇失败

持续失败更容易与以下方向相关：

```text
配置完全错误
容器无法启动
依赖完全不可达
权限拒绝
没有可用 Endpoint
Pod 无法调度
```

间歇失败要重点考虑：

```text
部分 Endpoint 异常
部分 Node 或 Pod 异常
负载均衡后的目标不一致
容量饱和
共享依赖抖动
DNS 或网络超时
```

这只是调查优先级，不是根因结论。

### Step 4：查最近变化

事故突然发生时，先建立变化时间线：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab rollout history deployment/gateway

kubectl --context kind-incident-lab `
  -n incident-lab get rs,job --sort-by=.metadata.creationTimestamp

kubectl --context kind-incident-lab `
  -n incident-lab get events --sort-by=.lastTimestamp
```

变化与事故时间接近，只能提高相关性，不能单独证明因果关系。

### Step 5：提出多个可证伪假设

差的假设：

```text
Kubernetes 有问题。
```

更好的假设：

```text
我怀疑失败只来自部分 Service Endpoint。
如果正确，我应该看到：
1. 成功和失败请求同时存在；
2. EndpointSlice 中存在多组目标；
3. 失败与其中一组目标相关。

如果所有 Endpoint 配置和单目标请求都一致成功，这个假设应该被降低优先级。
```

### Step 6：选择最高信息增益命令

不要问“还能运行什么命令”，而要问：

```text
哪条命令最能区分当前两个假设？
```

例如：

```text
假设 A：Pod 根本没有启动
假设 B：Pod 已启动，但 Service 没有把流量送到它

高信息增益：get pod + EndpointSlice
低信息增益：再次查看整个命名空间的完整 YAML
```

### Step 7：缓解优先，根因分析在恢复后完成

缓解动作要写清楚：

```text
预期收益
风险
爆炸半径
回滚方法
负责人
成功指标
```

### Step 8：从客户边界验证恢复

至少覆盖：

```text
客户请求是否连续成功？
错误率和延迟是否回到正常范围？
相关依赖是否恢复？
队列是否停止增长并开始清空？
存储读写是否都成功？
DNS/共享基础设施是否恢复？
```

---

## 9. 开始动手前：确认安全上下文

这些场景只允许在一次性专用 kind 集群运行。

进入仓库：

```powershell
Set-Location D:\workshop\aug\k8s-incident-lab
```

查看当前上下文：

```powershell
kubectl config current-context
kubectl config get-contexts
```

本实验室预期上下文：

```text
kind-incident-lab
```

确认节点拓扑：

```powershell
kubectl --context kind-incident-lab get nodes -o wide
```

必须看到：

```text
1 个 control-plane
3 个 worker
所有节点 Ready
```

不要把场景命令指向共享集群、公司集群或生产集群。

---

## 10. 建立健康基线

当前集群已经完成 E2E，学习时先运行：

```powershell
.\scripts\Test-Lab.ps1 -Context kind-incident-lab
```

真正通过时，输出会包含：

```text
kind topology: 1 control-plane + 3 workers
lab pods: all Ready
restricted diagnostic workloads: Ready
PVCs: all Bound
gateway: 3 consecutive HTTP 200
catalog: 3 consecutive HTTP 200
orders: 3 consecutive HTTP 202
storage: 3 consecutive HTTP 201
storage-read: 3 consecutive HTTP 200
CoreDNS: 2 replicas Ready
KEDA worker ScaledObject: Ready
Prometheus Server is Ready.
Prometheus targets: all up
BASELINE_PASS context=kind-incident-lab
```

每一行证明的事情不同：

| 输出 | 证明内容 |
|---|---|
| `nodes Ready` | 集群节点层当前可用 |
| `pods all Ready` | 工作负载探针当前通过 |
| `PVCs all Bound` | 声明和卷已绑定 |
| HTTP 200/201/202 | 代表性客户路径真实成功 |
| DNS resolved 5/5 | Pod 内真实服务发现可用 |
| `CoreDNS replicas Ready` | DNS 工作负载副本就绪 |
| `ScaledObject Ready` | KEDA 队列伸缩对象可工作 |
| `Prometheus targets all up` | 指标证据源当前可采集 |

只有最后出现 `BASELINE_PASS`，才能把当前环境作为事故练习起点。

如果基线失败：

1. 停止启动 Incident；
2. 记录第一个失败门；
3. 使用本指南的分层方法调查；
4. 修复或重建一次性环境；
5. 从头重新运行 `Test-Lab.ps1`。

---

## 11. 小实验 1：画出集群和工作负载地图

目标：不查源代码，只根据运行时对象解释“什么运行在哪里”。

### 11.1 查看 Node

```powershell
kubectl --context kind-incident-lab get nodes -o wide
```

你要解释：

```text
NAME
STATUS
ROLES
VERSION
```

### 11.2 查看命名空间

```powershell
kubectl --context kind-incident-lab get namespace
```

重点识别：

```text
incident-lab
lab-observability
keda
kube-system
```

### 11.3 查看 Pod 放置

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods -o wide
```

记录：

```text
Pod 名称
Ready
Status
Restarts
Pod IP
Node
Age
```

### 11.4 完成标准

你能够不用看答案，画出：

```text
Node
  └── Pod
        └── 所属 Deployment / StatefulSet
```

并解释为什么 Pod 分散到不同 Node 能减少部分节点故障的影响。

---

## 12. 小实验 2：比较期望状态和观察状态

目标：读懂 Deployment、StatefulSet 和 Pod 的运行时状态。

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deployment,statefulset
```

进一步查看 gateway：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe deployment gateway
```

查看精确字段：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deployment gateway `
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,UPDATED:.status.updatedReplicas'
```

你要回答：

```text
期望副本数是多少？
Ready 和 Available 是否相同？
当前 Pod 使用哪个镜像？
最近一次 rollout 是否完成？
```

完成标准：你能解释“控制器已达到期望状态”为什么仍不足以证明客户健康。

---

## 13. 小实验 3：从 Service 追到真实 Pod

目标：完整追踪一条 Kubernetes Service 数据路径。

### 13.1 查看 Service

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get service gateway -o yaml
```

记录：

```text
selector
port
targetPort
```

### 13.2 找匹配的 Pod

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods `
  -l app.kubernetes.io/name=gateway `
  --show-labels
```

### 13.3 查看 EndpointSlice

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get endpointslice `
  -l kubernetes.io/service-name=gateway `
  -o wide
```

更精确地查看地址、端口和目标：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get endpointslice `
  -l kubernetes.io/service-name=gateway `
  -o custom-columns='NAME:.metadata.name,PORT:.ports[*].port,ADDRESSES:.endpoints[*].addresses,TARGETS:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready'
```

### 13.4 画出证据链

```text
Service selector
  = Pod labels

Service targetPort
  = EndpointSlice port

EndpointSlice targetRef
  = 实际 gateway Pod
```

完成标准：你能从 Service 独立找到所有真实目标，并解释 selector 或端口不一致会在哪一层表现出来。

---

## 14. 小实验 4：学会读 Events 和 Logs

目标：根据对象当前阶段选择正确证据。

### 14.1 读取近期 Events

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get events --sort-by=.lastTimestamp
```

常见 Reason：

```text
Scheduled
Pulling / Pulled
Created / Started
Unhealthy
FailedScheduling
FailedMount
Killing
```

Events 可能过期，也可能重复聚合，所以必须记录时间，并结合对象状态。

### 14.2 读取当前容器日志

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/gateway `
  --since=5m --tail=100
```

### 14.3 容器重启时读取上一实例日志

先找到具体 Pod：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods `
  -l app.kubernetes.io/name=gateway
```

然后：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs <gateway-pod-name> `
  --previous --tail=100
```

只有发生过容器重启时，`--previous` 才有内容。

### 14.4 完成标准

给出下面三种情况时，你能选择第一条命令：

```text
Pod Pending              → describe Pod / Events
Container repeatedly     → describe Pod + previous logs
  restarting
Pod Ready but request    → Service path + application/dependency logs
  failing
```

---

## 15. 小实验 5：从 CPU 扩展到容量思维

目标：理解 Metrics 是证据，不是自动结论。

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab top pods

kubectl --context kind-incident-lab `
  -n incident-lab get hpa,scaledobject

kubectl --context kind-incident-lab `
  -n incident-lab describe hpa gateway
```

查看 requests 和 limits：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods `
  -o custom-columns='NAME:.metadata.name,CPU_REQUEST:.spec.containers[*].resources.requests.cpu,CPU_LIMIT:.spec.containers[*].resources.limits.cpu,MEM_REQUEST:.spec.containers[*].resources.requests.memory,MEM_LIMIT:.spec.containers[*].resources.limits.memory'
```

必须理解：

```text
HPA CPU utilization
  通常是当前 CPU 使用量相对于 CPU request 的比例
```

CPU 不高时，仍可能存在：

```text
并发上限
线程或连接池
队列积压
下游限流
磁盘等待
DNS 等待
网络超时
```

完成标准：看到高延迟时，你不会只运行 `kubectl top` 就宣布容量正常或异常。

---

## 16. 小实验 6：识别异步、存储和 DNS 健康

目标：理解 HTTP 健康之外的业务完成条件。

### 16.1 Queue

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area queue
```

重点字段：

```text
Queue depth
Oldest message age
Worker replicas
HPA / ScaledObject
Worker logs
```

判断队列恢复时，不能只看 depth 是否暂时降低，还要确认到达速率不再长期高于处理速率。

### 16.2 Storage

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area storage
```

区分：

```text
PVC Bound
Mount 成功
文件系统权限正确
应用可以读取
应用可以写入
数据状态符合预期
```

它们是不同证据门。

### 16.3 DNS

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area dns
```

关注：

```text
CoreDNS replicas
CoreDNS CPU
查询量
查询延迟
超时率
真实解析结果
跨服务失败范围
```

完成标准：你能够分别定义同步 HTTP、异步队列、存储读写和 DNS 的“客户恢复”。

---

## 17. 小实验 7：生成一次健康系统调查记录

目标：在没有事故时，先练习完整证据记录。

运行汇总证据：

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area summary
```

然后填写：

```text
Observation Time:

Kubernetes Context:

Customer Health:
  gateway:
  catalog:
  orders:
  storage write:
  storage read:

Cluster Topology:

Workload Health:

Gateway Service Selector:

Gateway Endpoint Count:

Recent Relevant Events:

CPU / HPA State:

Queue State:

Storage State:

DNS State:

Prometheus Target Health:

Known Facts:

Inferences:

Unknowns:
```

注意：健康系统也存在 Events、历史重启或短暂抖动。不要把任何 Warning 自动解释为当前事故，必须检查事件时间和当前客户症状。

---

## 18. 事实、推断和未知项必须分开

示例：

```text
事实：
  gateway 有 3 个 Ready Pod。
  客户请求中存在超时。
  EndpointSlice 包含 3 个 Ready 地址。

推断：
  故障可能不在 Deployment 可用性层。

未知：
  三个 Endpoint 是否都能完成相同请求？
  下游依赖是否一致健康？
```

错误写法：

```text
三个 Pod 都 Ready，所以 Kubernetes 没问题。
```

这句话把有限事实扩大成了没有证据支持的结论。

---

## 19. 建立假设表

每次 Incident 至少维护两个候选假设：

| 假设 | 如果为真，预期看到什么 | 什么证据会削弱它 | 下一条命令 | 当前状态 |
|---|---|---|---|---|
| A |  |  |  | Open |
| B |  |  |  | Open |
| C |  |  |  | Open |

状态建议只使用：

```text
Open
Supported
Rejected
Confirmed
```

不要因为第一个假设被拒绝就认为调查失败。能够用证据拒绝错误假设，是合格事故响应的重要能力。

---

## 20. 通用调查命令的推荐顺序

以下顺序是起点，不是固定脚本。根据症状跳到信息价值最高的区域。

### 20.1 快速范围扫描

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods -o wide

kubectl --context kind-incident-lab `
  -n incident-lab get deployment,statefulset

kubectl --context kind-incident-lab `
  -n incident-lab get service,endpointslice

kubectl --context kind-incident-lab `
  -n incident-lab get events --sort-by=.lastTimestamp
```

### 20.2 最近变化

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area changes
```

### 20.3 Service 数据路径

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area service-path
```

### 20.4 容量

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area capacity
```

### 20.5 专项区域

```powershell
# 异步系统
.\learner\Get-RuntimeEvidence.ps1 -Context kind-incident-lab -Area queue

# 存储
.\learner\Get-RuntimeEvidence.ps1 -Context kind-incident-lab -Area storage

# DNS / 共享基础设施
.\learner\Get-RuntimeEvidence.ps1 -Context kind-incident-lab -Area dns
```

不要一开始机械执行所有命令。每次运行前先写：

```text
我为什么要运行它？
它将区分哪两个假设？
什么结果会改变我的下一步？
```

---

## 21. 常见错误

### 错误 1：看到 Pod Running 就停止

改进：继续验证 readiness、Service、Endpoint 和客户路径。

### 错误 2：先重启再调查

重启可能暂时缓解，也可能销毁最有价值的现场证据。

改进：先记录状态、Events、日志、指标和时间；只有明确评估风险后再缓解。

### 错误 3：只看 CPU

改进：同时考虑请求并发、队列、依赖、磁盘、DNS 和网络。

### 错误 4：把相关性当成因果

“刚发布过”值得优先调查，但仍需要版本、日志、请求结果等交叉证据。

### 错误 5：一次抓取整个集群全部 YAML

大量输出不等于高质量证据。

改进：围绕假设选择范围明确的字段、对象和时间窗口。

### 错误 6：只找支持自己的证据

改进：主动寻找能够推翻当前结论的证据。

### 错误 7：把 Warning 当成当前根因

旧 Event 可能来自启动阶段，和当前客户症状无关。

改进：比较时间、对象状态和当前指标。

### 错误 8：只验证内部对象，不验证客户恢复

改进：最后必须重新验证真实请求及适用的队列、存储或 DNS 状态。

---

## 22. 第一阶段结业任务

不要启动 Incident。先在健康环境完成一份 `Baseline Investigation Report`，内容至少包括：

1. 当前 context 和四节点拓扑；
2. `incident-lab` 中 Deployment、StatefulSet 和 Pod 的关系；
3. gateway Service selector、端口、EndpointSlice 和目标 Pod；
4. 五条代表性客户路径的状态；
5. 最近 5 分钟 gateway 日志；
6. 最近 Events，并区分历史事件和当前异常；
7. HPA、KEDA 和 Pod CPU 状态；
8. Queue、Storage、DNS 各自的健康定义；
9. Prometheus targets 是否全部可用；
10. 已知事实、推断和未知项。

最后再运行：

```powershell
.\scripts\Test-Lab.ps1 -Context kind-incident-lab
```

结业证据必须包含：

```text
BASELINE_PASS context=kind-incident-lab
```

### 第一阶段通过标准

只有同时满足以下条件，才建议进入 INC-01：

- 能画出实验室请求路径；
- 能解释 Pod Running、Ready、Deployment Available 和客户健康的差别；
- 能从 Service 找到全部 Endpoint；
- 能根据 Pending、Restarting、Ready-but-failing 选择不同证据；
- 能写出至少两个可证伪假设；
- 能说明下一条命令为什么具有高信息增益；
- 能从客户边界定义恢复；
- 健康基线实际通过。

---

## 23. 完成第一阶段后怎样进入场景学习

进入具体故障场景后，优先使用无答案材料：

- [Learner 排障手册](k8s-incident-learner-playbook-zh.md)
- `learner/briefs/INC-XX.md`
- Learner Runtime Evidence Tool
- Kubernetes 运行时状态、日志、指标和 Events

第一次练习一个场景时，不要先查看：

```text
scenario-builder implementation
evaluator/rubrics
Owner 手册中的对应根因章节
Git diff 或应用源代码中的故障机制
```

推荐从 INC-01 开始，一次只做一个场景。完成自己的调查记录、缓解决定和恢复验证之后，再用 [Owner 排障手册](k8s-incident-owner-troubleshooting-handbook-zh.md) 对照复盘。

---

## 24. 最终记住这四句话

```text
Kubernetes 对象健康，不等于客户健康。

一条可疑线索，不等于 Root Cause。

正确猜测但没有证据，不等于完成调查。

恢复必须由客户路径和业务状态共同证明。
```
