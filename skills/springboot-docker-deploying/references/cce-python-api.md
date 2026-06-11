# CCE API via Python urllib (Workaround)

When the terminal tool blocks `curl` with client certificates, use Python's `urllib` with `ssl.SSLContext` instead.

## Connection Setup

```python
import ssl, json, urllib.request

# 替换为实际的 CCE API 地址和证书路径
CCE_API = "https://<cluster-ip>:<port>"
CCE_CERT_DIR = "/path/to/ccecert"

ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ssl_ctx.load_verify_locations(f'{CCE_CERT_DIR}/ca.crt')
ssl_ctx.load_cert_chain(f'{CCE_CERT_DIR}/client.crt', f'{CCE_CERT_DIR}/client.key')
```

## GET Request (e.g., list pods)

```python
CCE_NAMESPACE = "default"
url = f"{CCE_API}/api/v1/namespaces/{CCE_NAMESPACE}/pods"
req = urllib.request.Request(url)
with urllib.request.urlopen(req, context=ssl_ctx, timeout=10) as resp:
    data = json.loads(resp.read())
```

## PATCH Request (e.g., update deployment image)

```python
DEPLOY_NAME = "<deployment-name>"
IMAGE_TAG = "<swr-repo>:<tag>"
url = f"{CCE_API}/apis/apps/v1/namespaces/{CCE_NAMESPACE}/deployments/{DEPLOY_NAME}"

patch_body = json.dumps({
    "spec": {
        "template": {
            "spec": {
                "containers": [{
                    "name": DEPLOY_NAME,
                    "image": IMAGE_TAG
                }]
            }
        }
    }
}).encode('utf-8')

req = urllib.request.Request(url, data=patch_body, method='PATCH')
req.add_header('Content-Type', 'application/strategic-merge-patch+json')

with urllib.request.urlopen(req, context=ssl_ctx, timeout=15) as resp:
    data = json.loads(resp.read())
```

## Parse Deployment Status

```python
containers = data['spec']['template']['spec']['containers']
status = data.get('status', {})
print(f"镜像: {containers[0]['image']}")
print(f"副本: {status['replicas']}  就绪: {status.get('readyReplicas',0)}")
```

## Parse Pod Status

```python
DEPLOY_NAME = "<deployment-name>"
for p in data['items']:
    if DEPLOY_NAME in p['metadata']['name']:
        s = p['status']
        cs = s.get('containerStatuses', [{}])[0]
        print(f"Pod: {p['metadata']['name']}  状态: {s['phase']}  IP: {s.get('podIP','N/A')}  重启: {cs.get('restartCount',0)}  就绪: {cs.get('ready',False)}")
```
