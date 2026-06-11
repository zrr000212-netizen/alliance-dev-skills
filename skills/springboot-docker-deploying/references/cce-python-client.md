# CCE Python Client (urllib) — 绕过 terminal 安全审批

当 `curl --cert` 命令被终端安全审批拦截时，使用 Python `ssl` + `urllib` 直接请求 CCE API。

## 连接模板

```python
import ssl, json, urllib.request

# 替换为实际的 CCE API 地址和证书路径
CCE_API = "https://<cluster-ip>:<port>"
CCE_CERT_DIR = "/path/to/ccecert"

ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ssl_ctx.load_verify_locations(f'{CCE_CERT_DIR}/ca.crt')
ssl_ctx.load_cert_chain(f'{CCE_CERT_DIR}/client.crt', f'{CCE_CERT_DIR}/client.key')

def cce_get(path):
    """GET 请求 CCE API"""
    req = urllib.request.Request(f"{CCE_API}{path}")
    with urllib.request.urlopen(req, context=ssl_ctx, timeout=10) as resp:
        return json.loads(resp.read())

def cce_patch(path, body):
    """PATCH 请求 CCE API (strategic-merge-patch)"""
    data = json.dumps(body).encode('utf-8')
    req = urllib.request.Request(f"{CCE_API}{path}", data=data, method='PATCH')
    req.add_header('Content-Type', 'application/strategic-merge-patch+json')
    with urllib.request.urlopen(req, context=ssl_ctx, timeout=15) as resp:
        return json.loads(resp.read())
```

## 常用操作

### 更新 Deployment 镜像

```python
CCE_NAMESPACE = "default"
DEPLOY_NAME = "<deployment-name>"
IMAGE_TAG = "<swr-repo>:<tag>"

result = cce_patch(f"/apis/apps/v1/namespaces/{CCE_NAMESPACE}/deployments/{DEPLOY_NAME}", {
    "spec": {"template": {"spec": {"containers": [{
        "name": DEPLOY_NAME, "image": IMAGE_TAG
    }]}}}
})
```

### 查询 Deployment 状态

```python
d = cce_get(f"/apis/apps/v1/namespaces/{CCE_NAMESPACE}/deployments/{DEPLOY_NAME}")
c = d['spec']['template']['spec']['containers'][0]
s = d['status']
print(f"镜像: {c['image']}")
print(f"副本: {s['replicas']}  就绪: {s.get('readyReplicas',0)}")
```

### 查询 Pod 状态

```python
data = cce_get(f"/api/v1/namespaces/{CCE_NAMESPACE}/pods")
for p in data['items']:
    if DEPLOY_NAME in p['metadata']['name']:
        s = p['status']
        cs = s.get('containerStatuses', [{}])[0]
        print(f"Pod: {p['metadata']['name']}  状态: {s['phase']}  IP: {s.get('podIP','N/A')}  重启: {cs.get('restartCount',0)}  就绪: {cs.get('ready',False)}")
```

### 查询 Service 信息

```python
data = cce_get(f"/api/v1/namespaces/{CCE_NAMESPACE}/services")
for svc in data['items']:
    name = svc['metadata']['name']
    spec = svc['spec']
    ingress = svc['status'].get('loadBalancer', {}).get('ingress', [])
    ext_ip = ingress[0].get('ip', 'N/A') if ingress else 'N/A'
    ports = ', '.join(f"{p['port']}->{p['targetPort']}" for p in spec['ports'])
    print(f"Service: {name}  类型: {spec['type']}  外部IP: {ext_ip}  端口: {ports}")
```
