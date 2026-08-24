# Owner 私有评分细则 — INC-07

## 标准答案（Ground Truth）

- 根因：一次完成的存储维护 Job 改变了 PVC 文件系统树的写权限，使现有 StatefulSet 保持 Ready，但新的持久化写入被文件系统拒绝。
- 触发因素：`storage-maintenance` 对已挂载的 `data-storage-0` 执行策略变更。
- 促成因素：本地健康探针不执行持久化写入；维护验收没有做读写验证或权限不变量检查。

## 期望证据

- Storage Pod Ready、PVC Bound、CPU 正常，但写入失败而只读路径仍成功。
- 存储错误指标和应用日志表明文件系统/数据库写入被拒绝。
- PVC/PV、挂载点、已完成 Job 和文件权限证据共同支持结论。

## 可接受缓解

- 停止进一步写入风险，恢复预期所有权/权限并验证读写；不应删除 PVC 或在没有备份判断时重建状态。

## 常见错误假设

- PVC Pending、CPU 饱和、Service 路由故障、数据库锁竞争、直接删除 StatefulSet/PVC。

## 纠正措施方向

- 存储维护预检、权限策略测试、合成持久化读写探针、备份/恢复演练和明确 RTO/RPO。
