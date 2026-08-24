# Owner 私有评分细则 — INC-05

## 标准答案（Ground Truth）

- 根因：渐进式 Gateway revision 的就绪端口与 Service 数据端口不一致；其 Pod 被判定 Ready 并进入 EndpointSlice，但部分转发连接无法到达应用监听器。
- 触发因素：`gateway-rollout` 版本加入现有 Gateway Service 后端集合。
- 促成因素：就绪检查没有验证与 Service 相同的数据平面端口，发布验收只检查 Deployment 可用性。

## 期望证据

- 稳定和新 revision 均 Ready，Gateway EndpointSlice 非空且包含多个 Ready 地址。
- 客户请求同时存在成功和失败，Catalog 直接路径保持成功。
- Endpoint targetRef、Pod 端口/环境与 Service targetPort 的联合证据解释部分失败。

## 可接受缓解

- 从流量路径移除有问题的 revision，或恢复一致的数据平面监听配置；验证连续成功率和错误率。

## 常见错误假设

- Service 没有 Endpoint、全部 Gateway Pod 故障、Catalog/Identity 整体不可用、集群容量不足。

## 纠正措施方向

- 对实际 Service 端口执行 readiness、金丝雀客户路径探测、按 revision 观察成功率和发布自动中止。
