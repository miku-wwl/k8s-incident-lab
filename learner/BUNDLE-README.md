# 学员安全包

此目录是本次 GameDay 唯一允许提供给学员和教练 Codex 的文件材料。

## 强制进程边界

这个九文件包证明 Owner 内容没有被复制进来，但单独切换宿主机工作目录并不能阻止同一 Windows 用户读取 Owner 仓库。Coach AI 进程必须通过 Owner 的 Docker 隔离启动器运行；容器中只挂载本目录和只读、短时、最小权限 kubeconfig：

```powershell
.\scripts\Start-CoachSandbox.ps1 `
  -BundlePath C:\gameday\INC-XX `
  -Context kind-incident-lab `
  -Interactive
```

默认镜像提供隔离的 PowerShell/kubectl 调查 shell。实际 Coach AI CLI 必须安装并启动在同一容器边界内；从 Owner checkout 或宿主机直接启动的 Codex **不符合隔离要求**。Owner 仓库是控制面；本学员包是调查面。

允许使用：

- `incident-brief.md`
- 时间线、调查和事后复盘模板
- `Get-RuntimeEvidence.ps1`
- 教练工作契约
- 事件管理评分卡
- Kubernetes 运行时状态、日志、指标、事件和发布历史

禁止请求或查看：应用源代码、Git 历史或差异、场景构建器脚本、Evaluator Rubric、Ground Truth，以及仓库级故障线索搜索结果。

完成调查和 RCA 后，把填写完成的 `postmortem.md` 交给场景 Owner。只有在调查正式关闭、场景已经恢复后，Owner 才能生成 Evaluator 包。
