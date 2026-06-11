#!/bin/bash
# Spring Boot 后端一键部署脚本：构建 → SWR推送 → CCE更新
# 用法: ./deploy.sh <backend_dir> <deploy_name> <swr_repo> [cce_api] [cce_cert_dir]
#
# 前置条件:
#   - JAVA_HOME 已配置 (JDK 17)
#   - docker 已登录 SWR
#   - CCE 证书已放置在 CCE_CERT_DIR
#
# 环境变量(可选):
#   SWR_USER      - SWR登录用户名
#   SWR_PASSWORD  - SWR登录密码
#   SWR_REGISTRY  - SWR仓库域名 (默认: swr.cn-north-4.myhuaweicloud.com)
#   CCE_NAMESPACE - CCE命名空间 (默认: default)
#   JDK_CACHE     - JDK缓存路径 (默认: /tmp/jdk17-x64.tar.gz)

set -euo pipefail

BACKEND_DIR="${1:?用法: $0 <backend_dir> <deploy_name> <swr_repo> [cce_api] [cce_cert_dir]}"
DEPLOY_NAME="${2:?用法: $0 <backend_dir> <deploy_name> <swr_repo> [cce_api] [cce_cert_dir]}"
SWR_REPO="${3:?用法: $0 <backend_dir> <deploy_name> <swr_repo> [cce_api] [cce_cert_dir]}"
CCE_API="${4:-$CCE_API}"
CCE_CERT_DIR="${5:-$CCE_CERT_DIR}"
CCE_NAMESPACE="${CCE_NAMESPACE:-default}"
SWR_CENTOS="swr.cn-north-4.myhuaweicloud.com/library/centos:7"
JDK_URL="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz"

echo "============================================"
echo " Spring Boot 一键部署 (构建→SWR→CCE)"
echo "============================================"
echo "后端目录: $BACKEND_DIR"
echo "SWR仓库:  $SWR_REPO"
echo "CCE部署:  $DEPLOY_NAME"
echo "CCE API:  $CCE_API"
echo ""

# ===== Step 1: Maven 构建 JAR =====
echo "[1/8] Maven 构建 JAR..."
cd "$BACKEND_DIR"
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}
export PATH=$JAVA_HOME/bin:$PATH
mvn clean package -DskipTests -q
JAR_FILE=$(find target -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -1)
if [ -z "$JAR_FILE" ]; then
    echo "✗ JAR 构建失败"
    exit 1
fi
JAR_SIZE=$(ls -lh "$JAR_FILE" | awk '{print $5}')
echo "  ✓ JAR: $JAR_FILE ($JAR_SIZE)"

# ===== Step 2: 下载 x86_64 JDK =====
echo "[2/8] 下载 x86_64 JDK..."
cd /root
if [ -f /tmp/jdk17-x64.tar.gz ]; then
    echo "  使用缓存"
    cp /tmp/jdk17-x64.tar.gz jdk17-x64.tar.gz
else
    wget -q -O jdk17-x64.tar.gz "$JDK_URL"
    cp jdk17-x64.tar.gz /tmp/jdk17-x64.tar.gz
fi
tar -xzf jdk17-x64.tar.gz
JDK_DIR=$(ls -d jdk-17.*)
echo "  ✓ JDK: $JDK_DIR"

# ===== Step 3: 提取 CentOS 7 amd64 rootfs =====
echo "[3/8] 提取 CentOS 7 amd64 rootfs..."
if [ -f /tmp/centos7-rootfs.tar ]; then
    cp /tmp/centos7-rootfs.tar /root/centos7-rootfs.tar
else
    docker save "$SWR_CENTOS" -o /root/centos7-image.tar
    python3 - <<'PYEOF'
import tarfile, json, shutil
src = '/root/centos7-image.tar'
dst = '/root/centos7-rootfs.tar'
with tarfile.open(src, 'r') as tin:
    manifest = json.loads(tin.extractfile('manifest.json').read())
    layer_path = manifest[0]['Layers'][0]
    layer_file = tin.extractfile(tin.getmember(layer_path))
    with open(dst, 'wb') as fout:
        while True:
            chunk = layer_file.read(8192)
            if not chunk: break
            fout.write(chunk)
shutil.copy2(dst, '/tmp/centos7-rootfs.tar')
PYEOF
fi
echo "  ✓ rootfs: $(ls -lh /root/centos7-rootfs.tar | awk '{print $5}')"

# ===== Step 4: 组装 rootfs =====
echo "[4/8] 组装 rootfs..."
cd /root
rm -rf rootfs && mkdir -p rootfs
cd rootfs
tar -xf ../centos7-rootfs.tar
mkdir -p usr/lib/jvm app tmp
cp -a "../$JDK_DIR" usr/lib/jvm/java-17-openjdk
mkdir -p lib64
cp usr/lib64/ld-2.17.so lib64/ld-linux-x86-64.so.2
ln -sf /usr/lib/jvm/java-17-openjdk/bin/java usr/bin/java 2>/dev/null || true
cp "$BACKEND_DIR/$JAR_FILE" app/app.jar
echo "  ✓ rootfs 组装完成"

# ===== Step 5: 导入镜像 + 修正架构 + ENTRYPOINT =====
echo "[5/8] 构建镜像 (修正架构 amd64 + ENTRYPOINT)..."
TAG=$(date +%Y%m%d%H%M%S)
IMAGE_TAG="${SWR_REPO}:${TAG}"

cd /root
tar -cf rootfs.tar -C rootfs .
docker import rootfs.tar "$IMAGE_TAG" > /dev/null

docker save "$IMAGE_TAG" -o /root/image.tar

export IMAGE_TAG
python3 - <<'PYEOF'
import json, tarfile, io, os

image_tag = os.environ.get("IMAGE_TAG")
tar_path = '/root/image.tar'
output_path = '/root/image-fixed.tar'

with tarfile.open(tar_path, 'r') as tin:
    manifest_data = json.loads(tin.extractfile('manifest.json').read())
    config_file = manifest_data[0]['Config']
    config_data = json.loads(tin.extractfile(config_file).read())

    config_data['architecture'] = 'amd64'
    config_data['config']['Entrypoint'] = ['java', '-jar', '/app/app.jar']
    config_data['config']['ExposedPorts'] = {'8080/tcp': {}}
    config_data['config']['WorkingDir'] = '/app'
    config_data['config']['Env'] = [
        'JAVA_HOME=/usr/lib/jvm/java-17-openjdk',
        'PATH=/usr/lib/jvm/java-17-openjdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    ]

    new_config_json = json.dumps(config_data, indent=2).encode('utf-8')

    with tarfile.open(output_path, 'w') as tout:
        for member in tin.getmembers():
            if member.name == config_file:
                info = tarfile.TarInfo(name=config_file)
                info.size = len(new_config_json)
                info.mode = member.mode
                info.uid = member.uid
                info.gid = member.gid
                info.mtime = member.mtime
                tout.addfile(info, io.BytesIO(new_config_json))
            else:
                tout.addfile(member, tin.extractfile(member))
PYEOF

IMAGE_TAG="${SWR_REPO}:${TAG}"
docker rmi "$IMAGE_TAG" 2>/dev/null || true
docker load -i /root/image-fixed.tar > /dev/null

ARCH=$(docker inspect "$IMAGE_TAG" --format='{{.Architecture}}')
if [ "$ARCH" != "amd64" ]; then
    echo "  ✗ 架构验证失败: $ARCH (期望 amd64)"
    exit 1
fi
echo "  ✓ 镜像: $IMAGE_TAG (arch=$ARCH)"

# ===== Step 6: 登录 SWR + 推送 =====
echo "[6/8] 登录 SWR + 推送镜像..."
if [ -n "${SWR_USER:-}" ] && [ -n "${SWR_PASSWORD:-}" ]; then
    SWR_REGISTRY="${SWR_REGISTRY:-swr.cn-north-4.myhuaweicloud.com}"
    docker login -u "$SWR_USER" -p "$SWR_PASSWORD" "$SWR_REGISTRY" > /dev/null 2>&1
    echo "  ✓ SWR 登录成功"
else
    echo "  ⚠ SWR_USER/SWR_PASSWORD 未设置，假设已登录"
fi
docker push "$IMAGE_TAG"
echo "  ✓ 推送完成"

# ===== Step 7: 更新 CCE Deployment =====
echo "[7/8] 更新 CCE Deployment (Python urllib)..."
export CCE_API CCE_CERT_DIR CCE_NAMESPACE DEPLOY_NAME IMAGE_TAG
python3 - <<'PYEOF'
import ssl, json, urllib.request, os

cce_api = os.environ["CCE_API"]
cce_cert_dir = os.environ["CCE_CERT_DIR"]
namespace = os.environ["CCE_NAMESPACE"]
deploy_name = os.environ["DEPLOY_NAME"]
image_tag = os.environ["IMAGE_TAG"]

ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ssl_ctx.load_verify_locations(f'{cce_cert_dir}/ca.crt')
ssl_ctx.load_cert_chain(f'{cce_cert_dir}/client.crt', f'{cce_cert_dir}/client.key')

url = f"{cce_api}/apis/apps/v1/namespaces/{namespace}/deployments/{deploy_name}"
patch_body = json.dumps({
    "spec": {"template": {"spec": {"containers": [{
        "name": deploy_name, "image": image_tag
    }]}}}
}).encode('utf-8')

req = urllib.request.Request(url, data=patch_body, method='PATCH')
req.add_header('Content-Type', 'application/strategic-merge-patch+json')
with urllib.request.urlopen(req, context=ssl_ctx, timeout=15) as resp:
    print(f"  ✓ CCE 已更新: {image_tag}")
PYEOF

# ===== Step 8: 验证部署 =====
echo "[8/8] 验证部署 (等待30秒)..."
sleep 30

echo ""
echo "============================================"
echo " 部署信息"
echo "============================================"

export CCE_API CCE_CERT_DIR CCE_NAMESPACE DEPLOY_NAME
python3 - <<'PYEOF'
import ssl, json, urllib.request, os

cce_api = os.environ["CCE_API"]
cce_cert_dir = os.environ["CCE_CERT_DIR"]
namespace = os.environ["CCE_NAMESPACE"]
deploy_name = os.environ["DEPLOY_NAME"]

ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ssl_ctx.load_verify_locations(f'{cce_cert_dir}/ca.crt')
ssl_ctx.load_cert_chain(f'{cce_cert_dir}/client.crt', f'{cce_cert_dir}/client.key')

url = f"{cce_api}/apis/apps/v1/namespaces/{namespace}/deployments/{deploy_name}"
with urllib.request.urlopen(url, context=ssl_ctx, timeout=10) as resp:
    d = json.loads(resp.read())
    c = d['spec']['template']['spec']['containers'][0]
    s = d['status']
    print(f'镜像: {c["image"]}')
    print(f'副本: {s["replicas"]}  就绪: {s.get("readyReplicas",0)}  更新: {s.get("updatedReplicas",0)}')

url2 = f"{cce_api}/api/v1/namespaces/{namespace}/pods"
with urllib.request.urlopen(url2, context=ssl_ctx, timeout=10) as resp:
    for p in json.loads(resp.read())['items']:
        if deploy_name in p['metadata']['name']:
            s = p['status']
            cs = s.get('containerStatuses', [{}])[0]
            print(f'Pod: {p["metadata"]["name"]}  状态: {s["phase"]}  重启: {cs.get("restartCount",0)}  就绪: {cs.get("ready",False)}')
PYEOF

# ===== 清理临时文件 =====
echo ""
echo "清理临时文件..."
rm -rf /root/rootfs /root/centos7-rootfs.tar /root/centos7-image.tar /root/rootfs.tar \
       /root/image.tar /root/image-fixed.tar \
       /root/jdk17-x64.tar.gz /root/$JDK_DIR
echo "✓ 部署完成"
