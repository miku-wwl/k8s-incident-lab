# 学员安全包

此目录是本次 GameDay 唯一允许提供给学员和教练 Codex 的文件材料。

## 强制工作目录边界

Coach Codex **必须以这个生成后的学员目录作为工作目录启动**，不得以 Owner 仓库 checkout 作为工作目录。先进入本目录，再启动一个全新的 Coach 会话：

```powershell
Set-Location C:\gameday\INC-XX
# 从这里启动 Coach Codex，并提供 COACH-PROMPT.md
```

Owner 仓库是控制面；本学员包是调查面。Coach 不需要、也不得拥有 Owner 仓库的文件系统访问权限。

允许使用：

- `incident-brief.md`
- 时间线、调查和事后复盘模板
- `Get-RuntimeEvidence.ps1`
- 教练工作契约
- 事件管理评分卡
- Kubernetes 运行时状态、日志、指标、事件和发布历史

禁止请求或查看：应用源代码、Git 历史或差异、场景构建器脚本、Evaluator Rubric、Ground Truth，以及仓库级故障线索搜索结果。

完成调查和 RCA 后，把填写完成的 `postmortem.md` 交给场景 Owner。只有在调查正式关闭、场景已经恢复后，Owner 才能生成 Evaluator 包。
