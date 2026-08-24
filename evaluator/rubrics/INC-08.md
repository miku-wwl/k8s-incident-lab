# Owner 私有评分细则 — INC-08

## 标准答案（Ground Truth）

- 根因：一次 Resolver 容量 rollout 限制 CoreDNS CPU，同时高基数服务发现探测显著放大查询量；CPU throttling 和重试导致间歇性 DNS 超时，并传播为跨服务调用失败。
- 触发因素：集群级 resolver 资源变更与新的 discovery probe 同时生效。
- 促成因素：共享 DNS 容量没有负载保护，应用依赖调用对解析延迟敏感，重试会进一步增加压力。

## 期望证据

- CoreDNS Pod 仍 Ready，Service/EndpointSlice 有效，但查询量、查询 p95 或超时明显上升。
- 多条跨服务路径间歇失败，仍保留部分成功；DNS 运行时采样也呈现混合结果。
- 应用 Pod 大多健康，失败跨越多个看似无关的服务。

## 可接受缓解

- 降低异常查询压力并恢复安全的 Resolver 容量；验证 DNS 延迟、跨服务成功率和客户路径恢复。

## 常见错误假设

- 每个应用独立故障、Service 没有 Endpoint、CoreDNS Pod 全部崩溃、单一应用发布失败。

## 纠正措施方向

- DNS 容量门、查询基数/速率告警、客户端缓存与退避、受控 resolver 发布和共享依赖负载测试。
