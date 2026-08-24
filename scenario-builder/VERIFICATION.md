# 场景构建器验收证据

日期：2026-08-24

上下文：`kind-incident-lab`
集群：kind v0.32.0、Kubernetes v1.36.1、一个控制平面节点和两个工作节点

这是场景构建器私有文件。不要提供给学员或教练。

## 健康基线证据门

- Gateway EndpointSlice：3 个有效地址。
- 客户路径：gateway `200`、catalog `200`、orders `202`、storage `201`；每条路径均连续三次请求成功。
- Prometheus：已就绪，所有已发现目标均正常。
- kube-state-metrics：在最终探针/RBAC 修正后为 `1/1 Running`，重启次数为零。
- Gateway HPA：最终基线采样中为 3 个副本，CPU 为 2% / 65% 目标值。
- KEDA worker ScaledObject：已就绪；队列为空时处于非活跃状态，worker 副本数为 2。
- Redis 和 storage PVC：通过默认 local-path StorageClass 成功绑定。
- CoreDNS：2/2 已就绪；原始资源已恢复，没有残留场景规则。
- 两个应用镜像版本均以 UID `10001` 运行。

## 复现证据门

| 事件 | 已接受的运行时症状证据 |
|---|---|
| INC-01 | Gateway 在版本 `2.0.0` 上仍为 3/3 Available；gateway 5xx 达到约 2.90/s，运行时日志记录了依赖 `ReadTimeout`。 |
| INC-02 | Gateway 5xx 达到约 81.91/s；HPA 仍保持 3 个副本，并报告 26% / 65% CPU。 |
| INC-03 | 维护排空操作将目标工作节点标记为已封锁，并留下 4 个处于 Pending 的 gateway Pods。 |
| INC-04 | 共享依赖失败达到约 1.30/s；两个共享服务 Pods 的 CPU 约为 107m 和 193m。 |
| INC-05 | Gateway Deployment/Pods 仍健康，但 EndpointSlice 地址数为零；代表性客户请求失败约为 2.30/s。 |
| INC-06 | 队列深度达到 1,213，最老消息年龄为 16.2 秒，同时两个工作节点仍已就绪。 |
| INC-07 | 有状态写入错误达到约 0.80/s，同时 StatefulSet 与 PVC 仍保持运行/绑定状态。 |
| INC-08 | CoreDNS 保持 2/2 已就绪，同时 5 条代表性 Service 路径全部失败，Pod 内 DNS 查询返回临时解析失败。 |

每次复现通过后都执行了 `Reset-Scenario.ps1`。最后一个场景重置后，最终健康基线证据门通过。

## 仓库证据门

- `tests/Validate-Repository.ps1`：通过。
- Kustomize 成功渲染基础和可观测性包：通过。
- Kubernetes API 对基础、可观测性、KEDA 和场景运行时对象执行服务端 dry-run：通过。
- Docker 成功构建版本 `1.0.0` 和 `2.0.0`：通过。
- 学员事件工作区生成结果恰好包含四个预期 Markdown 文件：通过。
- `git diff --check`：通过。
