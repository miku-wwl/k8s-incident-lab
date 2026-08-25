# Kubernetes Incident Lab —— Learner 排障手册（无答案版）

> **适用对象：** Learner / On-call SRE 练习
> **是否包含剧透：** 否
> **目标：** 教你怎么调查，而不是告诉你答案。
>
> 本文件可以作为学员训练手册使用，但仍应遵循仓库当前 Learner Bundle allowlist 和 Owner/Learner 隔离规则。

---

# 1. 你的角色

你现在不是实验室开发者。

你是：

```text
On-call SRE
```

你不知道：

```text
Root Cause
Injection mechanism
Ground Truth
Evaluator answer
Scenario implementation
```

你只知道：

```text
客户正在出问题。
```

你的任务是：

```text
确认症状
   ↓
确定影响范围
   ↓
建立假设
   ↓
找证据
   ↓
排除错误方向
   ↓
确认最可能根因
   ↓
提出安全缓解方案
   ↓
确认客户恢复
```

---

# 2. 最重要的规则

## 规则 1

不要把：

```text
Pod Running
```

理解成：

```text
服务健康
```

---

## 规则 2

不要把：

```text
Deployment Available
```

理解成：

```text
客户请求正常
```

---

## 规则 3

不要把：

```text
PVC Bound
```

理解成：

```text
应用一定能正常写数据
```

---

## 规则 4

不要只看 CPU。

真正的瓶颈可能是：

```text
Concurrency
Queue
Disk
Network
DNS
Dependency
Scheduling
```

---

## 规则 5

不要一找到“看起来可疑”的东西就宣布 Root Cause。

至少找：

```text
2 个独立证据
```

支持你的结论。

---

# 3. 开始实验前

Owner 应该已经完成：

```text
Start-Lab
Baseline Validation
Incident Activation
```

你开始调查之前，只需要确认：

```text
Incident Brief
Learner Runtime Evidence Tool
kubectl access
Grafana / Prometheus access
```

不要读取：

```text
scenario-builder
evaluator
rubrics
Ground Truth
solution
answer
Owner-only docs
```

---

# 4. 通用排障流程

每一个 Incident 都按下面流程走。

---

## Step 1 —— 先描述客户症状

不要先看 Kubernetes。

先写：

```text
客户到底看到了什么？
```

例如：

```text
5xx
Timeout
Latency
写失败
请求成功但业务没完成
间歇失败
多个服务一起失败
```

---

## Step 2 —— 判断 Blast Radius

写清楚：

```text
一个 Pod？
一个 Deployment？
一个 Service？
多个 Service？
一个 Node？
Cluster-wide？
```

这是非常重要的线索。

---

## Step 3 —— 判断是“持续失败”还是“间歇失败”

持续失败：

```text
所有请求都坏
```

通常和：

```text
配置
Crash
缺失依赖
调度
权限
```

更相关。

间歇失败：

```text
有些成功
有些失败
```

要重点考虑：

```text
部分 Endpoint
部分 Pod
负载均衡
共享依赖容量
DNS
网络
```

---

# 5. 第一组命令：快速扫一遍

## Pods

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods -o wide
```

观察：

```text
Ready
Status
Restarts
Node
Age
```

---

## Deployments

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get deploy
```

观察：

```text
Desired
Ready
Available
```

---

## Services

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get svc
```

---

## EndpointSlices

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get endpointslice
```

---

## Events

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get events --sort-by=.lastTimestamp
```

---

# 6. 第二组命令：最近发生了什么

当 Incident 突然发生，先问：

```text
最近有没有变更？
```

可以查看：

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area changes
```

以及：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab rollout history deployment/<name>
```

重点找：

```text
新版本
配置变化
Replica 变化
Node maintenance
Job
Scaling object
```

---

# 7. 第三组命令：日志

例如：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs deployment/gateway --tail=100
```

调查日志时重点找：

```text
timeout
connection refused
permission denied
request rejected
dependency failure
DNS
queue
retry
```

不要只找 ERROR。

很多真实问题日志可能只是：

```text
warning
timeout
rejected
slow
```

---

# 8. 第四组命令：Metrics

先问：

```text
哪个指标最能解释客户症状？
```

不要机械看 CPU。

---

## Pod CPU / Memory

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab top pods
```

---

## HPA

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get hpa
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe hpa <name>
```

---

## 需要关注的指标类型

```text
Request Rate
5xx Rate
p95 Latency
CPU
Replica Count
Queue Depth
Oldest Message Age
DNS Latency
DNS Timeout Rate
```

---

# 9. 第五组：Service 数据路径

如果你遇到：

```text
Pod 都 Ready
但请求间歇失败
```

请完整调查：

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
真实应用监听端口
```

命令：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get svc <service-name> -o yaml
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get endpointslice `
  -l kubernetes.io/service-name=<service-name> -o yaml
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get pods -o wide
```

你应该比较：

```text
Service port
targetPort
containerPort
named port
readiness port
application listener
```

---

# 10. 第六组：Scheduling / Node

如果出现：

```text
Pod Pending
Deployment Ready 数下降
Node maintenance
```

优先看：

```powershell
kubectl --context kind-incident-lab get nodes
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab describe pod <pending-pod>
```

重点看：

```text
Events
FailedScheduling
```

再检查：

```text
nodeSelector
affinity
taints
tolerations
PDB
```

---

# 11. 第七组：Queue / Async

如果出现：

```text
API 成功
但业务处理越来越慢
```

不要只看 HTTP。

看：

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area queue
```

检查：

```text
Queue Depth
Oldest Message Age
Worker Replicas
Producer Rate
Consumer Throughput
```

再看：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get scaledobject
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get hpa
```

核心问题：

```text
Arrival Rate
是否大于
Processing Rate
```

---

# 12. 第八组：Storage

如果出现：

```text
Read 成功
Write 失败
```

不要只看：

```text
PVC Bound
```

还要看：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get sts,pvc
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab get jobs
```

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab logs statefulset/storage -c app --tail=100
```

如果允许使用 inspector：

```powershell
kubectl --context kind-incident-lab `
  -n incident-lab exec storage-inspector-0 -- `
  sh -c 'id; df -h /data; ls -ld /data; ls -la /data | head'
```

重点看：

```text
permissions
ownership
mount
free space
filesystem state
```

不要做破坏性操作。

---

# 13. 第九组：DNS / 共享基础设施

如果出现：

```text
多个服务一起随机 timeout
```

要马上想到：

```text
共享基础设施
```

包括：

```text
DNS
Node
Network
Service routing
Shared dependency
```

如果怀疑 DNS：

```powershell
.\learner\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area dns
```

然后：

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

重点看：

```text
Ready
CPU
Latency
Timeout
Retry
Blast Radius
```

---

# 14. 如何建立一个好假设

差：

```text
Gateway 有问题。
```

好：

```text
Gateway 的客户错误来自其某个下游依赖路径，
并且问题可能和最近的 rollout 有关。
```

更好：

```text
新版本可能改变了 Gateway 的依赖调用行为，
导致当前请求在下游正常完成之前提前失败。
```

好的假设应该满足：

```text
具体
可验证
可被反驳
```

---

# 15. 如何反证自己

每次你觉得“找到答案了”，问自己：

```text
什么证据会证明我是错的？
```

例如你怀疑某服务：

```text
如果这个服务真是根因，
为什么其他依赖路径仍然健康？
```

你怀疑 CPU：

```text
如果 CPU 是瓶颈，
为什么 CPU 并没有达到饱和？
```

你怀疑 Endpoint：

```text
如果 Endpoint 不存在，
为什么部分请求还能成功？
```

---

# 16. 每次调查都写 Investigation Notes

推荐模板：

```text
Incident:

Customer Symptom:

Blast Radius:

Timeline:

Recent Changes:

Evidence #1:

Evidence #2:

Evidence Against My Hypothesis:

Current Hypothesis:

Alternative Hypothesis:

Next Highest-Information Command:

Likely Root Cause:

Safe Mitigation:

Recovery Validation:
```

---

# 17. “最高信息增益命令”思维

不要一次执行 20 条 kubectl。

每次问：

```text
如果我只能执行下一条命令，
哪条命令最能区分我的两个假设？
```

例如：

```text
假设 A：
Gateway 自己坏了

假设 B：
下游依赖坏了
```

这时比：

```text
kubectl get pods
```

更有价值的可能是：

```text
Gateway logs
+
Downstream logs
```

---

# 18. 避免这些常见错误

## 错误 1

```text
Pod Running
→ 没问题
```

---

## 错误 2

```text
CPU 不高
→ 容量没问题
```

---

## 错误 3

```text
PVC Bound
→ Storage 没问题
```

---

## 错误 4

```text
EndpointSlice 非空
→ Service Path 没问题
```

---

## 错误 5

```text
最近刚 Deploy
→ Deployment 一定是 Root Cause
```

---

## 错误 6

```text
三个服务都失败
→ 三个服务各自有 Bug
```

---

## 错误 7

```text
202 Accepted
→ 业务完成
```

---

## 错误 8

```text
CoreDNS Ready
→ DNS 一定健康
```

---

# 19. 推荐的 8 个场景学习顺序

```text
INC-01
先学发布和依赖
   ↓
INC-02
再学容量和 Autoscaling
   ↓
INC-03
再学 Scheduling / Maintenance
   ↓
INC-04
再学 Shared Dependency
   ↓
INC-05
再学 Service Data Plane
   ↓
INC-06
再学 Async / Queue
   ↓
INC-07
再学 Stateful Storage
   ↓
INC-08
最后学 Cluster Shared Infrastructure
```

---

# 20. 结束一个 Incident 前

你应该能回答：

```text
客户症状是什么？

Blast Radius 是什么？

第一个错误假设是什么？

哪条证据让你改变方向？

Root Cause 是什么？

为什么这个 Root Cause 能解释所有症状？

最安全的缓解方案是什么？

如何确认客户真的恢复？
```

如果答不上这些，只执行了 Reset，不算真正练完。

---

# 21. Recovery 验证

Owner 完成恢复后，至少确认：

```text
Baseline 恢复
Customer Path 恢复
无异常 Pending Pod
无残留场景状态
关键 Metrics 回落
```

不要只确认：

```text
Pod 又 Running 了
```

---

# 22. 最终目标

练完这 8 个 Incident 后，你应该形成这样的肌肉记忆：

```text
Customer Symptom
      ↓
Blast Radius
      ↓
Recent Change
      ↓
Metrics / Logs / Events
      ↓
Hypothesis
      ↓
Cross-check
      ↓
Root Cause
      ↓
Safe Mitigation
      ↓
Customer Recovery
```

最终不要问：

```text
答案是什么？
```

而要问：

```text
下一条最有信息价值的证据是什么？
```
