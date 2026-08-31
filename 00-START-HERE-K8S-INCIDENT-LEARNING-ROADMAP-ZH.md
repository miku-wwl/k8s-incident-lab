# 00 — START HERE：Kubernetes 事故定位学习总路线

> 这是本仓库的学习导航入口。
> 不确定下一步看什么时，就回到这个文件。
> 核心原则：先从健康环境学习通用定位框架，再独立调查场景，最后才查看答案和复盘。

---

## 一条主线

这个项目不是用来背 Kubernetes 命令的，而是训练一套生产事故定位闭环：

```text
客户症状
  ↓
影响范围
  ↓
最近变更
  ↓
运行时证据
  ↓
可证伪假设
  ↓
低风险缓解
  ↓
客户路径恢复
  ↓
RCA / 复盘
```

你真正要练出的能力是：

```text
看到现象
  ↓
判断范围
  ↓
选择最高信息增益的调查
  ↓
用证据排除假设
  ↓
控制风险地缓解
  ↓
从客户角度验证恢复
```

---

## 文档地图

### 1. 总路线

当前文件：

```text
00-START-HERE-K8S-INCIDENT-LEARNING-ROADMAP-ZH.md
```

用途：决定当前处于哪个学习阶段，以及下一步做什么。

### 2. 第一阶段详细教材

[第一阶段：通用事故定位框架](k8s-incident-stage-1-general-troubleshooting-guide-zh.md)

用途：以 CKAD 基础为起点，学习 Pod、Deployment、Service、EndpointSlice、Events、Logs、Metrics、Queue、Storage、DNS 和证据推理。

### 3. Learner 排障手册

[Learner 排障手册（无答案版）](k8s-incident-learner-playbook-zh.md)

用途：实际调查 Incident 时使用，故意不暴露根因和注入方式。

### 4. Owner 排障手册

[Owner 排障与复盘手册](k8s-incident-owner-troubleshooting-handbook-zh.md)

用途：包含场景操作、根因和恢复方式。只有完成自己的调查和 RCA 后再看。

### 5. 实验室生命周期和边界

[仓库 README](README.md)

用途：了解实验室启动、隔离、安全边界、Learner Bundle、Evaluator 和完整生命周期。

### 6. 评分标准

[`learner/scorecard.md`](learner/scorecard.md)

用途：理解真正的评价标准不是“猜中根因”，而是影响评估、假设质量、证据、缓解决定、恢复验证和 RCA 质量。

---

## 第一阶段：先学通用定位框架

这一阶段不要启动故障。

使用健康环境熟悉下面这条路径：

```text
客户请求
  ↓
Gateway
  ↓
Service
  ↓
EndpointSlice
  ↓
Pod
  ↓
下游依赖 / Queue / Storage / DNS
```

先运行健康门：

```powershell
.\scripts\Test-Lab.ps1 -Context kind-incident-lab
```

只有看到下面这一行，才把环境当成健康起点：

```text
BASELINE_PASS context=kind-incident-lab
```

### 第一组基础命令

```powershell
kubectl --context kind-incident-lab -n incident-lab get pods -o wide
kubectl --context kind-incident-lab -n incident-lab get deployment
kubectl --context kind-incident-lab -n incident-lab get service
kubectl --context kind-incident-lab -n incident-lab get endpointslice
kubectl --context kind-incident-lab -n incident-lab get events --sort-by=.lastTimestamp
kubectl --context kind-incident-lab -n incident-lab top pods
```

核心不是记命令，而是每次都回答：

1. 客户坏了什么？
2. 影响一个 Pod、一个 Service、一个 Node，还是多个服务？
3. 是持续失败还是间歇失败？
4. 最近发生了什么变更？
5. 哪个证据最能区分当前两个假设？

### 第一阶段完成标准

进入具体 Incident 前，你应该能够：

- 解释 `Pod Running`、`Pod Ready`、`Deployment Available` 和客户健康的区别；
- 从 Service selector 找到匹配的 Pod；
- 从 EndpointSlice 找到真实地址、端口和目标 Pod；
- 判断应该先看 Events、Logs 还是 Metrics；
- 写出两个可证伪假设；
- 说明下一条命令为什么具有高信息增益；
- 从客户请求、队列、存储或 DNS 定义恢复。

第一阶段的完整学习与小实验都在：

[第一阶段详细指南](k8s-incident-stage-1-general-troubleshooting-guide-zh.md)

---

## 第二阶段：按难度递进跑 8 个 Incident

学习顺序：

| 顺序 | 场景类型 | 核心能力 |
|---|---|---|
| INC-01 | 发布后错误 | 从 rollout、日志和依赖延迟调查版本回归 |
| INC-02 | CPU 不高但容量不足 | 理解 CPU 不等于并发容量，判断伸缩信号是否有效 |
| INC-03 | Node maintenance | 理解 drain、PDB、调度约束和 Pending |
| INC-04 | 多服务同时失败 | 从 Blast Radius 寻找共同故障域和共享依赖 |
| INC-05 | Pod Ready 但请求间歇失败 | 追踪 Service、EndpointSlice、端口和真实数据路径 |
| INC-06 | API 成功但队列积压 | 区分 HTTP 接受请求和异步业务完成 |
| INC-07 | PVC Bound 但写失败 | 理解挂载、权限、读写、RTO/RPO 和数据风险 |
| INC-08 | CoreDNS Ready 但随机超时 | 调查共享基础设施容量、DNS 延迟和跨服务影响 |

学习时不要先看 Owner 手册对应章节，否则会变成“根据答案寻找证据”。

---

## 每个 Incident 的固定练习循环

### 1. 建立健康基线

```powershell
.\scripts\Test-Lab.ps1 -Context kind-incident-lab
```

如果不是 `BASELINE_PASS`，停止启动场景，先恢复健康环境。

### 2. 由 Owner 启动一个场景

以 INC-01 为例：

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

调查过程中只使用：

- Incident Brief；
- Learner 排障手册；
- Kubernetes 运行时对象；
- Logs；
- Events；
- Metrics；
- Grafana / Prometheus；
- Learner Runtime Evidence Tool。

不要查看：

```text
scenario-builder 实现
evaluator/rubrics
Owner 手册对应答案
应用源代码中的故障机制
Git diff 中的场景答案
```

### 3. 先写调查记录，再执行命令

每次至少填写：

```text
Customer Symptom:

Blast Radius:

Recent Changes:

Known Facts:

Unknowns:

Hypothesis A:

Hypothesis B:

Evidence supporting A:

Evidence rejecting B:

Next highest-information command:

Mitigation:

Recovery evidence:
```

### 4. 假设必须可以被证伪

差的假设：

```text
可能是 Kubernetes 有问题。
```

更好的写法：

```text
我怀疑失败只来自某一部分运行目标。

如果正确，应该同时看到：
1. 成功和失败请求并存；
2. 存在多组运行目标；
3. 失败能够和其中一组目标关联。

如果所有目标都表现一致，这个假设应该被降低优先级。
```

### 5. 找至少两个独立证据

例如：

- Kubernetes 发布历史 + 应用日志；
- EndpointSlice + 实际请求结果；
- Queue depth + oldest message age；
- PVC 状态 + 文件系统证据；
- CoreDNS CPU + DNS timeout 指标。

单独看到下面任意一个状态，都不能证明客户路径健康：

```text
Pod Running
Deployment Available
PVC Bound
CoreDNS Ready
```

### 6. 先控制客户影响，再完成根因分析

每个缓解决定都要说明：

```text
收益：
风险：
影响范围：
回滚方式：
负责人：
如何证明恢复：
```

不要为了“看起来修好了”直接删除 PVC、重启整个集群或执行没有回滚方案的高风险操作。

### 7. 重置并验证恢复

```powershell
.\scenario-builder\Reset-Scenario.ps1 `
  -Context kind-incident-lab

.\scripts\Test-Lab.ps1 `
  -Context kind-incident-lab
```

同时验证相应业务状态：

- HTTP：成功率、5xx、p95；
- Queue：积压、最老消息年龄、Worker 吞吐；
- Storage：读取、写入、持久化状态；
- DNS：真实解析、延迟、超时和跨服务请求。

上一场没有恢复干净，就不要开始下一场。

---

## 第三阶段：再看 Owner 手册和完成复盘

完成自己的调查记录和 `postmortem.md` 后，再查看 Owner 手册对应章节。

对照回答：

- 我的第一个假设是否具体、可证伪？
- 哪些关键证据被我漏掉了？
- 有没有把健康探针错误地当成客户健康？
- 有没有运行与当前假设无关的低信息量命令？
- 缓解是否有更小的 Blast Radius？
- 恢复是否真的从客户边界验证？
- RCA 是否区分根因、触发因素和促成因素？
- 纠正措施是否覆盖预防、检测和缓解？

---

## 当前建议的下一步

如果你还没有完成第一阶段：

1. 打开 [第一阶段详细指南](k8s-incident-stage-1-general-troubleshooting-guide-zh.md)；
2. 从“确认安全上下文”和“建立健康基线”开始；
3. 一次只完成一个小实验；
4. 每一步都解释命令输出，而不是只复制命令；
5. 完成第一阶段结业任务后，再进入 INC-01。

如果第一阶段已经完成，再开始：

```powershell
.\scripts\Test-Lab.ps1 -Context kind-incident-lab

.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

然后先写：

```text
Customer Symptom
Blast Radius
Recent Changes
Hypothesis A
Hypothesis B
```

写完再开始调查。

---

## 最后提醒

```text
会多少 kubectl 命令，不是目标。

能否用证据解释客户故障，才是目标。

猜中根因，不等于完成调查。

客户路径没有恢复，就不能宣布事件结束。
```
