[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Context,

    [ValidateSet("summary", "changes", "service-path", "capacity", "queue", "storage", "dns")]
    [string]$Area = "summary"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$namespace = "incident-lab"

if ($Context -notlike "kind-*") {
    throw "运行时取证仅允许使用一次性 kind 上下文；收到 '$Context'。"
}
$knownContext = & kubectl config get-contexts $Context -o name 2>$null
if ($LASTEXITCODE -ne 0 -or $knownContext -ne $Context) {
    throw "Kubernetes 上下文 '$Context' 不存在。"
}
$versionJson = (& kubectl --context $Context version -o json) -join "`n"
$version = $versionJson | ConvertFrom-Json
$clientMatch = [regex]::Match([string]$version.clientVersion.gitVersion, '^v(?<major>\d+)\.(?<minor>\d+)')
$serverMatch = [regex]::Match([string]$version.serverVersion.gitVersion, '^v(?<major>\d+)\.(?<minor>\d+)')
if (-not $clientMatch.Success -or -not $serverMatch.Success -or
    $clientMatch.Groups['major'].Value -ne $serverMatch.Groups['major'].Value -or
    [Math]::Abs([int]$clientMatch.Groups['minor'].Value - [int]$serverMatch.Groups['minor'].Value) -gt 1) {
    throw "kubectl 客户端与 Kubernetes 服务端版本偏差不受支持。"
}
$nodeJson = (& kubectl --context $Context get nodes -o json) -join "`n"
$nodes = ($nodeJson | ConvertFrom-Json).items
$controlPlaneCount = @($nodes | Where-Object {
    $null -ne $_.metadata.labels.'node-role.kubernetes.io/control-plane'
}).Count
$workerCount = @($nodes | Where-Object {
    $null -eq $_.metadata.labels.'node-role.kubernetes.io/control-plane'
}).Count
if ($controlPlaneCount -ne 1 -or $workerCount -ne 3) {
    throw "实验室拓扑必须精确为 1 个 control-plane 和 3 个 workers。"
}
$labId = & kubectl --context $Context get namespace $namespace `
    -o jsonpath='{.metadata.labels.training\.example\.com/lab-id}'
if ($labId -ne "k8s-incident-lab") {
    throw "命名空间 '$namespace' 不是预期的事件实验室。"
}

function Show-Command([string]$Label, [scriptblock]$Command) {
    Write-Output "`n### $Label"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "运行时取证命令失败：$Label"
    }
}

switch ($Area) {
    "summary" {
        Show-Command "工作负载" { kubectl --context $Context -n $namespace get deploy,statefulset,pods -o wide }
        Show-Command "Service" { kubectl --context $Context -n $namespace get services }
        Show-Command "近期事件" { kubectl --context $Context -n $namespace get events --sort-by=.lastTimestamp }
        Show-Command "症状型告警" { kubectl --context $Context get --raw '/api/v1/namespaces/lab-observability/services/http:prometheus:9090/proxy/api/v1/alerts' }
    }
    "changes" {
        Show-Command "发布历史" { kubectl --context $Context -n $namespace rollout history deployment/gateway }
        Show-Command "Deployment 版本与变更注解" { kubectl --context $Context -n $namespace get deployment -o custom-columns='NAME:.metadata.name,CHANGE:.metadata.annotations.kubernetes\.io/change-cause,IMAGES:.spec.template.spec.containers[*].image' }
        Show-Command "近期 ReplicaSet" { kubectl --context $Context -n $namespace get replicaset --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "近期 Job" { kubectl --context $Context -n $namespace get job --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "近期集群事件" { kubectl --context $Context -n $namespace get events --sort-by=.lastTimestamp }
    }
    "service-path" {
        Show-Command "Service" { kubectl --context $Context -n $namespace get services -o wide }
        Show-Command "EndpointSlice 地址与目标" { kubectl --context $Context -n $namespace get endpointslices -o custom-columns='NAME:.metadata.name,SERVICE:.metadata.labels.kubernetes\.io/service-name,PORTS:.ports[*].port,ADDRESSES:.endpoints[*].addresses,TARGETS:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready' }
        Show-Command "Gateway 工作负载和 Pods" { kubectl --context $Context -n $namespace get deployment,pods -l app.kubernetes.io/name=gateway -o wide }
        Show-Command "Gateway Service 运行时对象" { kubectl --context $Context -n $namespace get service/gateway -o yaml }
        Show-Command "Gateway Deployment 运行时对象" { kubectl --context $Context -n $namespace get deployment -l app.kubernetes.io/name=gateway -o yaml }
        Show-Command "代表性路径结果" { kubectl --context $Context get --raw '/api/v1/namespaces/lab-observability/services/http:prometheus:9090/proxy/api/v1/query?query=sum%20by%20%28target%2Cresult%29%20%28rate%28lab_load_requests_total%5B1m%5D%29%29' }
    }
    "capacity" {
        Show-Command "资源使用" { kubectl --context $Context -n $namespace top pods }
        Show-Command "自动伸缩" { kubectl --context $Context -n $namespace get hpa,scaledobject -o wide }
        Show-Command "资源 requests 与 limits" { kubectl --context $Context -n $namespace get pods -o custom-columns='NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,CPU_LIMIT:.spec.containers[*].resources.limits.cpu' }
    }
    "queue" {
        Show-Command "Worker" { kubectl --context $Context -n $namespace get deployment/worker -o wide }
        Show-Command "队列伸缩器" { kubectl --context $Context -n $namespace get hpa,scaledobject -o wide }
        Show-Command "队列信号" { kubectl --context $Context get --raw '/api/v1/namespaces/lab-observability/services/http:prometheus:9090/proxy/api/v1/query?query=max%28lab_queue_depth%29%20or%20max%28lab_oldest_message_age_seconds%29' }
        Show-Command "Worker 日志" { kubectl --context $Context -n $namespace logs deployment/worker --tail=80 }
    }
    "storage" {
        Show-Command "有状态对象" { kubectl --context $Context -n $namespace get statefulset,pvc -o wide }
        Show-Command "近期存储 Job" { kubectl --context $Context -n $namespace get job --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "近期 Pods" { kubectl --context $Context -n $namespace get pod --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "Storage 工作负载" { kubectl --context $Context -n $namespace describe statefulset/storage }
        Show-Command "挂载点与文件系统" { kubectl --context $Context -n $namespace exec pod/storage-inspector-0 -- sh -c 'id; df -h /data; ls -ld /data; ls -la /data | head -20' }
        Show-Command "Storage 读写信号" { kubectl --context $Context get --raw '/api/v1/namespaces/lab-observability/services/http:prometheus:9090/proxy/api/v1/query?query=sum%20by%20%28operation%29%20%28rate%28lab_storage_errors_total%5B1m%5D%29%29' }
        Show-Command "Storage 日志" { kubectl --context $Context -n $namespace logs statefulset/storage -c app --tail=100 }
    }
    "dns" {
        Show-Command "集群 DNS 对象" { kubectl --context $Context -n kube-system get deployment,pods,service,endpointslice -l k8s-app=kube-dns -o wide }
        Show-Command "集群 DNS 资源使用" { kubectl --context $Context -n kube-system top pods -l k8s-app=kube-dns }
        Show-Command "服务发现指标" { kubectl --context $Context get --raw '/api/v1/namespaces/lab-observability/services/http:prometheus:9090/proxy/api/v1/query?query=sum%28rate%28coredns_dns_requests_total%5B1m%5D%29%29%20or%20histogram_quantile%280.95%2Csum%20by%20%28le%29%20%28rate%28lab_dns_query_duration_seconds_bucket%5B1m%5D%29%29%29' }
        $dnsProbe = @'
import os
import socket
import struct
import time

with open("/etc/resolv.conf", encoding="utf-8") as resolv:
    nameserver = next(
        line.split()[1]
        for line in resolv
        if line.startswith("nameserver ")
    )

def query_packet(hostname):
    labels = hostname.rstrip(".").split(".")
    qname = b"".join(bytes([len(label)]) + label.encode("ascii") for label in labels) + b"\x00"
    return os.urandom(2) + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + qname + struct.pack("!HH", 1, 1)

for service in ["gateway", "catalog", "orders", "storage", "identity"]:
    name = f"{service}.incident-lab.svc.cluster.local"
    outcomes = []
    for _ in range(5):
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.settimeout(0.25)
        started = time.monotonic()
        try:
            client.sendto(query_packet(name), (nameserver, 53))
            response, _ = client.recvfrom(4096)
            rcode = response[3] & 0x0F
            result = "ok" if rcode == 0 else f"rcode-{rcode}"
            outcomes.append(f"{result}:{(time.monotonic() - started) * 1000:.1f}ms")
        except (TimeoutError, OSError) as exc:
            outcomes.append(f"{type(exc).__name__}:{(time.monotonic() - started) * 1000:.1f}ms")
        finally:
            client.close()
    print(service, " ".join(outcomes))
'@
        Show-Command "Pod 内 DNS 采样" { kubectl --context $Context -n $namespace exec pod/runtime-inspector-0 -- python -c $dnsProbe }
        Show-Command "CoreDNS 日志" { kubectl --context $Context -n kube-system logs deployment/coredns --tail=100 }
        Show-Command "跨服务失败日志" { kubectl --context $Context -n $namespace logs deployment/gateway --tail=80 }
    }
}
