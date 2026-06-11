#!/bin/bash
# Spring Boot 后端跨架构 Docker 镜像构建脚本
# 用途：在 aarch64 构建机上构建 amd64 Docker 镜像，用于华为云 CCE 部署
# 用法：./cross-arch-build.sh <jar_path> <image_tag> [swr_centos_image]
#
# 环境变量(可选):
#   JDK_URL     - JDK下载地址 (默认: 清华镜像 JDK 17)
#   JDK_CACHE   - JDK缓存路径 (默认: /tmp/jdk17-x64.tar.gz)

set -euo pipefail

JAR_PATH="${1:?用法: $0 <jar_path> <image_tag> [swr_centos_image]}"
IMAGE_TAG="${2:?用法: $0 <jar_path> <image_tag> [swr_centos_image]}"
SWR_CENTOS="${3:-swr.cn-north-4.myhuaweicloud.com/library/centos:7}"
JDK_URL="${JDK_URL:-https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz}"
JDK_CACHE="${JDK_CACHE:-/tmp/jdk17-x64.tar.gz}"
WORK_DIR="/root/cross-arch-build-$$"

echo "=== Spring Boot 跨架构 Docker 镜像构建 ==="
echo "JAR: $JAR_PATH"
echo "镜像: $IMAGE_TAG"
echo "基础镜像: $SWR_CENTOS"
echo "工作目录: $WORK_DIR"

# 1. 下载 x86_64 JDK（带缓存）
echo "[1/7] 下载 x86_64 JDK..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [ -f "$JDK_CACHE" ]; then
    echo "  使用缓存: $JDK_CACHE"
    cp "$JDK_CACHE" jdk17-x64.tar.gz
else
    wget -q -O jdk17-x64.tar.gz "$JDK_URL"
    cp jdk17-x64.tar.gz "$JDK_CACHE"
fi
tar -xzf jdk17-x64.tar.gz
JDK_DIR=$(ls -d jdk-17.*)
echo "  JDK 目录: $JDK_DIR"

# 2. 提取 x86_64 CentOS 7 rootfs（带缓存）
echo "[2/7] 提取 x86_64 CentOS 7 rootfs..."
ROOTFS_CACHE="/tmp/centos7-rootfs.tar"
if [ -f "$ROOTFS_CACHE" ]; then
    echo "  使用缓存: $ROOTFS_CACHE"
    cp "$ROOTFS_CACHE" centos7-rootfs.tar
else
    docker save "$SWR_CENTOS" -o centos7-image.tar
    python3 - <<'PYEOF'
import tarfile, json, shutil
src = 'centos7-image.tar'
dst = 'centos7-rootfs.tar'
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

# 验证 rootfs 架构
if ! tar -tf centos7-rootfs.tar | grep -q 'lib64/ld-linux-x86-64'; then
    echo "  ✗ rootfs 架构验证失败：未找到 x86_64 动态链接器，rootfs 可能是 aarch64"
    exit 1
fi
echo "  ✓ rootfs 架构: amd64"

# 3. 组装 rootfs
echo "[3/7] 组装 rootfs..."
rm -rf rootfs && mkdir -p rootfs
cd rootfs
tar -xf ../centos7-rootfs.tar
mkdir -p usr/lib/jvm app tmp
cp -a "../$JDK_DIR" usr/lib/jvm/java-17-openjdk
cp "$JAR_PATH" app/app.jar

mkdir -p lib64
cp usr/lib64/ld-2.17.so lib64/ld-linux-x86-64.so.2
ln -sf /usr/lib/jvm/java-17-openjdk/bin/java usr/bin/java 2>/dev/null || true
echo "  JAR 已复制: $(basename $JAR_PATH) -> app/app.jar"

# 4. 导入 Docker 镜像
echo "[4/7] 导入 Docker 镜像..."
cd "$WORK_DIR"
tar -cf rootfs.tar -C rootfs .
docker import rootfs.tar "$IMAGE_TAG" > /dev/null

# 5. 流式修正架构 + ENTRYPOINT
echo "[5/7] 流式修正架构 amd64 + ENTRYPOINT..."
docker save "$IMAGE_TAG" -o image.tar

python3 - <<'PYEOF'
import json, tarfile, io

tar_path = 'image.tar'
output_path = 'image-fixed.tar'

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

docker rmi "$IMAGE_TAG" 2>/dev/null || true
docker load -i image-fixed.tar > /dev/null

# 6. 验证
echo "[6/7] 验证镜像..."
ARCH=$(docker inspect "$IMAGE_TAG" --format='{{.Architecture}}')
SIZE=$(docker inspect "$IMAGE_TAG" --format='{{.Size}}' | awk '{printf "%.1f MB", $1/1048576}')
echo "  镜像: $IMAGE_TAG"
echo "  架构: $ARCH"
echo "  大小: $SIZE"

if [ "$ARCH" != "amd64" ]; then
    echo "  ✗ 架构验证失败: 期望 amd64, 实际 $ARCH"
    exit 1
fi
echo "  ✓ 架构验证通过"

# 7. 清理
echo "[7/7] 清理临时文件..."
rm -rf "$WORK_DIR"
echo "✓ 构建完成"
