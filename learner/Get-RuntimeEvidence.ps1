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
        Show-Command "工作负载" { kubectl --context $Context -n $namespace get deploy,statefulset,pods -o wide }
        Show-Command "Service" { kubectl --context $Context -n $namespace get services }
        Show-Command "近期事件" { kubectl --context $Context -n $namespace get events --sort-by=.lastTimestamp }
        Show-Command "症状型告警" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/alerts' }
    }
    "changes" {
        Show-Command "发布历史" { kubectl --context $Context -n $namespace rollout history deployment/gateway }
        Show-Command "Deployment 版本与变更注解" { kubectl --context $Context -n $namespace get deployment -o custom-columns='NAME:.metadata.name,CHANGE:.metadata.annotations.kubernetes\.io/change-cause,IMAGES:.spec.template.spec.containers[*].image' }
        Show-Command "近期 ReplicaSet 与 Job" { kubectl --context $Context -n $namespace get replicaset,job --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "近期集群事件" { kubectl --context $Context -n $namespace get events --sort-by=.lastTimestamp }
    }
    "service-path" {
        Show-Command "Service" { kubectl --context $Context -n $namespace get services -o wide }
        Show-Command "EndpointSlice 地址与目标" { kubectl --context $Context -n $namespace get endpointslices -o custom-columns='NAME:.metadata.name,SERVICE:.metadata.labels.kubernetes\.io/service-name,PORTS:.ports[*].port,ADDRESSES:.endpoints[*].addresses,TARGETS:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready' }
        Show-Command "Gateway 工作负载和 Pods" { kubectl --context $Context -n $namespace get deployment,pods -l app.kubernetes.io/name=gateway -o wide }
        Show-Command "Gateway Service 运行时对象" { kubectl --context $Context -n $namespace get service/gateway -o yaml }
        Show-Command "Gateway Deployment 运行时对象" { kubectl --context $Context -n $namespace get deployment -l app.kubernetes.io/name=gateway -o yaml }
        Show-Command "代表性路径结果" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=sum%20by%20%28target%2Cresult%29%20%28rate%28lab_load_requests_total%5B1m%5D%29%29' }
    }
    "capacity" {
        Show-Command "资源使用" { kubectl --context $Context -n $namespace top pods }
        Show-Command "自动伸缩" { kubectl --context $Context -n $namespace get hpa,scaledobject -o wide }
        Show-Command "资源 requests 与 limits" { kubectl --context $Context -n $namespace get pods -o custom-columns='NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,CPU_LIMIT:.spec.containers[*].resources.limits.cpu' }
    }
    "queue" {
        Show-Command "Worker 与伸缩器" { kubectl --context $Context -n $namespace get deployment/worker,hpa,scaledobject -o wide }
        Show-Command "队列信号" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=max%28lab_queue_depth%29%20or%20max%28lab_oldest_message_age_seconds%29' }
        Show-Command "Worker 日志" { kubectl --context $Context -n $namespace logs deployment/worker --tail=80 }
    }
    "storage" {
        Show-Command "有状态对象" { kubectl --context $Context -n $namespace get statefulset,pvc,pv -o wide }
        Show-Command "近期存储 Job" { kubectl --context $Context -n $namespace get job --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "近期 Pods" { kubectl --context $Context -n $namespace get pod --sort-by=.metadata.creationTimestamp -o wide }
        Show-Command "Storage 工作负载" { kubectl --context $Context -n $namespace describe statefulset/storage }
        Show-Command "挂载点与文件系统" { kubectl --context $Context -n $namespace exec statefulset/storage -c app -- sh -c 'id; df -h /data; ls -ld /data; ls -la /data | head -20' }
        Show-Command "Storage 读写信号" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=sum%20by%20%28operation%29%20%28rate%28lab_storage_errors_total%5B1m%5D%29%29' }
        Show-Command "Storage 日志" { kubectl --context $Context -n $namespace logs statefulset/storage -c app --tail=100 }
    }
    "dns" {
        Show-Command "集群 DNS 对象" { kubectl --context $Context -n kube-system get deployment,pods,service,endpointslice -l k8s-app=kube-dns -o wide }
        Show-Command "集群 DNS 资源使用" { kubectl --context $Context -n kube-system top pods -l k8s-app=kube-dns }
        Show-Command "服务发现指标" { kubectl --context $Context -n lab-observability exec deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=sum%28rate%28coredns_dns_requests_total%5B1m%5D%29%29%20or%20histogram_quantile%280.95%2Csum%20by%20%28le%29%20%28rate%28lab_dns_query_duration_seconds_bucket%5B1m%5D%29%29%29' }
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
        Show-Command "Pod 内 DNS 采样" { kubectl --context $Context -n $namespace exec deployment/traffic-gateway -- python -c $dnsProbe }
        Show-Command "CoreDNS 日志" { kubectl --context $Context -n kube-system logs deployment/coredns --tail=100 }
        Show-Command "跨服务失败日志" { kubectl --context $Context -n $namespace logs deployment/gateway --tail=80 }
    }
}
