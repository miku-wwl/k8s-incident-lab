# Owner 私有评分细则 — INC-03

## 标准答案（Ground Truth）

- 根因：维护前的 placement 更新把 Gateway 限制到目标 worker，同时 PDB 被放宽为 `minAvailable: 0`；排空节点后副本无法在其余 worker 调度。
- 触发因素：对 primary worker 执行计划内 drain。
- 促成因素：维护变更没有联合验证调度约束、PDB 和剩余容量。

## 期望证据

- 目标节点被 cordon/drain，Gateway Pod Pending，调度事件解释约束冲突。
- PDB 与 Deployment 运行时 YAML 显示维护窗口内的变化。
- 其他 worker 仍 Ready，但不能承接 Gateway。

## 可接受缓解

- 暂停维护并 uncordon，移除不安全 placement，恢复保护性 PDB，然后验证客户路径。

## 常见错误假设

- 节点资源耗尽、镜像拉取失败、控制平面故障。

## 纠正措施方向

- 维护前调度模拟、PDB 策略门、拓扑分布验证和 drain 前客户路径检查。
