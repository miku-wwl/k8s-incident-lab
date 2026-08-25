# Kubernetes 事件管理实验室

这是一个覆盖八类事件的 Kubernetes GameDay 实战实验室，用于训练生产风格的 SRE 推理能力。实验室严格遵循以下生命周期：

```text
设计 -> 复现 -> 诊断 -> 缓解 -> 恢复 -> 根因分析 -> 事后复盘
```

环境会从健康状态启动，持续运行具有代表性的流量，并通过 Kubernetes 运行时状态、日志以及 Prometheus/Grafana 暴露症状。场景变更使用真实的发布、负载、中断、Service 路由、队列、有状态服务和 DNS 行为，不存在通过 `INCIDENT_MODE` 直接切换错误响应的做法。

## 安全边界

请只使用一次性的专用 kind 集群。部分场景会执行节点维护、存储维护或集群级服务发现压力操作。绝对不要针对共享集群或生产环境运行场景构建器命令。

所有会修改集群的脚本都必须显式传入 Kubernetes 上下文，并验证目标是带实验室标记的 kind 集群。受支持的共享拓扑是一个控制平面节点加三个工作节点。

## 前置条件

- Windows PowerShell 7+
- 运行 Linux 容器的 Docker Desktop
- `helm`
- 能访问互联网，以拉取容器镜像以及 metrics-server/KEDA Helm Chart

安装脚本会把固定版本的 `kind.exe` 和 `kubectl.exe` 下载到已被 Git 忽略的 `.tools/` 目录，使用官方发布校验和验证后使用，不会执行全局安装。

## 快速开始

```powershell
# 构建实验所需应用版本，创建一次性集群，安装 addons，
# 部署健康基线并等待所有组件 Ready。
.\scripts\Start-Lab.ps1 -CreateKindCluster

# 建立明确的健康基线证据门。
.\scripts\Test-Lab.ps1 -Context kind-incident-lab

# 打开本地 Grafana 和 Prometheus 端口转发。
.\scripts\Open-Dashboards.ps1 -Context kind-incident-lab
```

Grafana 地址为 `http://localhost:3000`，可使用匿名查看者权限访问。Prometheus 地址为 `http://localhost:9090`。

如果要使用已有的专用集群，请显式传入它的上下文：

```powershell
.\scripts\Start-Lab.ps1 -Context my-disposable-context
```

本实验室只支持 kind。自定义 kind 集群必须采用相同的四节点拓扑，并能够访问实验所需镜像。

## 运行一次 GameDay

场景构建器（Scenario Builder）和教练（Coach）必须使用不同的 Codex 会话。

### 1. 场景构建器会话

```powershell
.\scenario-builder\Start-Scenario.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab
```

场景构建器只会告诉学员场景已经就绪，以及中性描述的事件简报位于哪里。不要向教练分享场景构建器终端或仓库内部实现。

### 2. 生成仓库外学员安全包

```powershell
.\scenario-builder\New-LearnerBundle.ps1 `
  -Incident INC-01 `
  -OutputPath C:\gameday\INC-01
```

完整 Git checkout 属于 Owner 控制面，不能交给学员或教练。生成的安全包只包含：

```text
C:\gameday\INC-01\
├── incident-brief.md
├── timeline.md
├── investigation.md
├── postmortem.md
├── Get-RuntimeEvidence.ps1
├── COACH-PROMPT.md
├── scorecard.md
├── README.md
└── BUNDLE-CONTENTS.txt
```

你可以使用普通运行时命令，也可以收集范围明确的证据视图：

```powershell
& C:\gameday\INC-01\Get-RuntimeEvidence.ps1 `
  -Context kind-incident-lab `
  -Area summary
```

支持的 area 包括 `summary`、`changes`、`service-path`、`capacity`、`queue`、`storage` 和 `dns`。选择调查方向是响应者的判断，并不等于获得答案。

### 3. 隔离的教练进程

九文件安全包提供内容隔离，但同一 Windows 用户仅靠切换目录仍可能读取 Owner 仓库。必须由 Owner 从控制面启动 Docker 隔离边界：

```powershell
.\scripts\Start-CoachSandbox.ps1 `
  -BundlePath C:\gameday\INC-01 `
  -Context kind-incident-lab `
  -Interactive
```

默认镜像提供 PowerShell、固定版 kubectl 和学员调查工具。实际 Coach AI CLI 必须位于同一容器或经过相同负测试的派生镜像中；宿主机 Codex 不算隔离。容器只挂载学员包与只读短时 kubeconfig，不挂载 Owner checkout 或 Docker socket。Owner 仓库是控制面，生成的学员包是调查面。

Owner 可以在交付前运行真实负测试：

```powershell
.\tests\Test-CoachProcessIsolation.ps1 -Context kind-incident-lab
```

### 4. 恢复、提交 RCA 与证据门

学员应先自行决定并解释缓解方案。演练结束后，场景构建器可以恢复已知健康基线：

```powershell
.\scenario-builder\Reset-Scenario.ps1 -Context kind-incident-lab
.\scripts\Test-Lab.ps1 -Context kind-incident-lab
```

不能仅因为 Pods 显示 Running 就宣布事件已经恢复。必须验证客户请求、延迟/错误信号、受影响的分布式路径，以及适用场景中的队列或状态恢复。

学员提交填写完成的 `postmortem.md` 后，Owner 必须先重置场景并通过健康基线验证，才能生成仓库外 Evaluator 包：

```powershell
.\evaluator\New-EvaluationPackage.ps1 `
  -Incident INC-01 `
  -Context kind-incident-lab `
  -SubmissionPath C:\gameday\INC-01\postmortem.md `
  -OutputPath C:\gameday-evaluation\INC-01 `
  -InvestigationClosed
```

Ground Truth 只会出现在调查关闭后的 Evaluator 包中，不会进入学员安全包或教练会话。

## 训练轮次

| 轮次 | 事件 | 重点 |
|---|---|---|
| 1 | INC-01、INC-02、INC-03 | 发布、容量、维护，以及缓解优先的响应方式 |
| 2 | INC-04、INC-05、INC-06 | 共享故障域、Service 路径和异步系统健康 |
| 3 | INC-07、INC-08 | 有状态系统、存储和集群网络/DNS |

## 证据模型

必须把以下五道门分开：

1. **健康基线：** 工作负载已就绪，合成客户路径成功，指标可以查询。
2. **事件复现：** 日常操作或变更发生后，预期症状真实出现。
3. **学员响应：** 客户影响、严重级别、假设、缓解与恢复决定都有运行时证据支持。
4. **根因分析/事后复盘：** 恢复之后再完成根因、触发因素、促成因素和纠正措施。
5. **Evaluator：** 只有调查关闭并完成恢复验证后，才揭示 Ground Truth，并按 100 分评分卡评价事件纪律。

仓库检查通过，只能证明实验室实现的结构有效；它不能证明学员已经理解事件，也不能代替学员对事件作出最终判断。

## 仓库结构

```text
apps/lab-service/          可复用的同步、异步和有状态实验工作负载
evidence/                  不含答案的机器可读运行验证证据
platform/base/             健康工作负载、流量、HPA 和 PDB
platform/observability/    Prometheus、症状型告警、Grafana 和 kube-state-metrics
platform/addons/           固定镜像的 addons、KEDA 队列伸缩和学员最小权限 RBAC
platform/coach/            只包含 PowerShell 与固定版 kubectl 的 Coach 隔离镜像
learner/                   安全简报、模板、教练契约和运行时辅助脚本
scenario-builder/          私有注入、恢复脚本和仅限场景构建器的说明
evaluator/                 Owner 私有 Ground Truth、评估打包和评分工作表
scripts/                   集群设置、基线验证和仪表盘脚本
tests/                     仓库静态验证
```

更详细的组件和隔离模型请参阅 [docs/architecture.md](docs/architecture.md)。

## 仓库验证

```powershell
.\tests\Validate-Repository.ps1
```

该脚本检查 Python 语法、PowerShell 解析、Kustomize/场景清单、四节点拓扑、评分卡总分、Evaluator 完整性、敏感信息以及学员可见内容的剧透边界。真实集群运行仍然是独立的证据层。

## 已验证实验版本

以下版本来自当前通过验证的本地环境，并由 `scripts/LabVersions.psd1` 统一维护：

| 组件 | 版本 |
|---|---|
| kind | `v0.32.0` |
| kubectl client | `v1.36.1` |
| Kubernetes | `v1.36.1` |
| KEDA chart / app | `2.20.2` / `2.20.2` |
| metrics-server chart / app | `3.14.0` / `0.9.0` |
| Prometheus | `v3.5.0` |
| Grafana | `12.1.1` |
| kube-state-metrics | `v2.15.0` |
| Python | `3.13.7` |

关键外部运行镜像同时固定 tag 与真实 registry digest；本地构建的 `k8s-incident-lab/service` 镜像未发布到 registry，因此保留 release tag，但其 Python 基础镜像已固定 digest。
