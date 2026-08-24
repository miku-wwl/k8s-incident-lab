[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [ValidateSet("summary", "changes", "service-path", "capacity", "queue", "storage", "dns")]
    [string]$Area = "summary"
)

$ErrorActionPreference = "Stop"
$namespace = "incident-lab"

function Show-Command([string]$Label, [scriptblock]$Command) {
    Write-Output "`n### $Label"
    & $Command
}
switch ($Area) {
    "summary" {
        Show-Command "Workloads" { kubectl --context $Context -n $namespace get deploy,statefulset,pods -o wide }
        Show-Command "Services" { kubectl --context $Context -n $namespace get services }
        Show-Command "Recent events" { kubectl --context $Context -n $namespace get events --sort-by=.lastTimestamp }
        Show-Command "Symptom alerts" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/alerts' }
    }
    "changes" {
        Show-Command "Gateway rollout history" { kubectl --context $Context -n $namespace rollout history deployment/gateway }
        Show-Command "Deployment annotations and images" { kubectl --context $Context -n $namespace get deployment -o custom-columns='NAME:.metadata.name,CHANGE:.metadata.annotations.kubernetes\.io/change-cause,IMAGES:.spec.template.spec.containers[*].image' }
    }
    "service-path" {
        Show-Command "Services" { kubectl --context $Context -n $namespace get services -o wide }
        Show-Command "EndpointSlices" { kubectl --context $Context -n $namespace get endpointslices -o wide }
        Show-Command "Gateway runtime object" { kubectl --context $Context -n $namespace get service/gateway deployment/gateway -o yaml }
    }
    "capacity" {
        Show-Command "Resource usage" { kubectl --context $Context -n $namespace top pods }
        Show-Command "Autoscaling" { kubectl --context $Context -n $namespace get hpa -o wide }
        Show-Command "Resource requests and limits" { kubectl --context $Context -n $namespace get pods -o custom-columns='NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,CPU_LIMIT:.spec.containers[*].resources.limits.cpu' }
    }
    "queue" {
        Show-Command "Worker and scaler" { kubectl --context $Context -n $namespace get deployment/worker,hpa,scaledobject -o wide }
        Show-Command "Queue signals" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=max(lab_queue_depth)%20or%20max(lab_oldest_message_age_seconds)' }
        Show-Command "Worker logs" { kubectl --context $Context -n $namespace logs deployment/worker --tail=80 }
    }
    "storage" {
        Show-Command "Stateful objects" { kubectl --context $Context -n $namespace get statefulset,pvc,pv -o wide }
        Show-Command "Storage workload" { kubectl --context $Context -n $namespace describe statefulset/storage }
        Show-Command "Storage logs" { kubectl --context $Context -n $namespace logs statefulset/storage -c app --tail=100 }
    }
    "dns" {
        Show-Command "Cluster DNS" { kubectl --context $Context -n kube-system get deployment,pods,service -l k8s-app=kube-dns -o wide }
        Show-Command "CoreDNS logs" { kubectl --context $Context -n kube-system logs deployment/coredns --tail=100 }
        Show-Command "Cross-service failure logs" { kubectl --context $Context -n $namespace logs deployment/gateway --tail=80 }
    }
}
