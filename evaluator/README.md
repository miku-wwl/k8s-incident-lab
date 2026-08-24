# 评估者控制面 — Owner 私有

`evaluator/` 只属于场景 Owner 和事后评估者，不能复制到学员安全包，也不能提供给教练会话。

## 强制生命周期

```text
场景构建器启动事件
  -> 学员与教练只收到安全包和运行时访问
  -> 学员提交 RCA
  -> 场景重置并完成健康基线验证
  -> Owner 使用 -InvestigationClosed 生成仓库外 Evaluator 包
  -> Evaluator 查看 Ground Truth 并填写评分卡
```

Ground Truth 保存在 `evaluator/rubrics/`，因此完整仓库本身属于 Owner 控制面。学员分发必须使用 `scenario-builder/New-LearnerBundle.ps1` 生成的仓库外安全包，不能把 Git checkout 交给学员或教练。

## 生成评估包

```powershell
.\evaluator\New-EvaluationPackage.ps1 `
  -Incident INC-05 `
  -Context kind-incident-lab `
  -SubmissionPath C:\gameday\INC-05\postmortem.md `
  -OutputPath C:\gameday-evaluation\INC-05 `
  -InvestigationClosed
```

脚本会拒绝以下情况：

- 场景仍处于激活状态
- 没有显式确认调查已经关闭
- 输出目录位于 Owner 仓库内部
- 输出目录已经存在

生成包包含学员提交、100 分评分卡、评估工作表和对应事件 Rubric。Evaluator 应引用提交中的证据评分，不应只根据是否猜中根因评分。
