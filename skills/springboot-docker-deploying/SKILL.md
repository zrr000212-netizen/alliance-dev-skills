---
name: springboot-docker-deploying
description: >
  Spring Boot 后端一键构建→SWR推送→CCE更新部署全流程。
  触发：用户说"打包部署"、"构建并部署"、"打包上传swr更新cce"等。
  前置技能：springboot-docker-packaging（跨架构构建细节）。
  不适用于：前端项目、非Spring Boot项目、非华为云CCE环境。
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [SpringBoot, Docker, CCE, SWR, Deploy]
    related_skills: [springboot-docker-packaging, springboot-vue-nginx-deployment]
---

# Spring Boot Docker 一键部署（构建 → SWR → CCE）

将 Spring Boot 后端项目从源码构建为 amd64 Docker 镜像，推送到华为云 SWR，并更新 CCE Deployment 完成滚动更新。

## 前置条件

- 构建机: aarch64 EulerOS 2.0+, Docker 18.09+ (experimental enabled)
- JDK 17 已安装或可下载
- Maven 3.6+ 已安装
- 华为云 SWR 登录凭证已获取
- CCE 集群 kubeconfig 或证书已配置
- springboot-docker-packaging 技能已加载（跨架构构建细节参考）

## 适用场景

- 用户说"打包部署"、"构建并部署"、"打包上传swr更新cce"
- Spring Boot 3.x + JDK 17 后端项目
- 构建机 aarch64，CCE 节点 x86_64（跨架构）

## 项目参数

| 参数 | 值 |
|------|-----|
| 后端目录 | /root/HDAgentSkillDev/backend |
| artifact | hd-skill-backend-1.0.0.jar |
| JDK 版本 | 17 |
| 容器端口 | 8080 |
| SWR 仓库 | swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend |
| CCE deployment | hd-skill-backend |
| CCE 命名空间 | default |
| 构建机架构 | aarch64 (EulerOS 2.0) |
| 目标架构 | amd64 (CCE x86_64) |

## SWR 登录信息

推送镜像前必须先登录 SWR，否则 `docker push` 会报 `unauthorized`。

```bash
docker login -u cn-north-4@HST3UQPSE9SU06K4QQ26 -p 6b215814cbb9a6266c14d030c19c02f574aa233273930eeab93774db15db8e07 swr.cn-north-4.myhuaweicloud.com
```

推送格式：

```bash
sudo docker push swr.cn-north-4.myhuaweicloud.com/{组织名称}/{镜像名称}:{版本名称}
# 本项目: swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:{TAG}
```

**陷阱：SWR 登录过期** — 登录凭证有时效，若 push 报 `unauthorized`，重新执行 docker login 即可。

## CCE 连接参数

| 参数 | 值 |
|------|-----|
| API 地址 | <https://192.168.1.214:5443> |
| CA 证书 | /root/lipeixin/ccecert/ca.crt |
| 客户端证书 | /root/lipeixin/ccecert/client.crt |
| 客户端密钥 | /root/lipeixin/ccecert/client.key |

CCE 证书获取方式（从集群节点下载）：

```bash
# 证书文件: ca.crt, client.crt, client.key
# 存放目录: /root/lipeixin/ccecert/
# 验证连接:
curl --cacert ./ca.crt --cert ./client.crt --key ./client.key \
  https://192.168.1.214:5443/api/v1/namespaces/default/pods/
```

**注意：CCE API 地址为 192.168.1.214:5443，请以实际集群地址为准。**

## 完整执行流程（8步）

### Step 1: Maven 构建 JAR

```bash
cd /root/HDAgentSkillDev/backend
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export PATH=$JAVA_HOME/bin:$PATH
mvn clean package -DskipTests
# 产出: target/hd-skill-backend-1.0.0.jar
```

验证：`ls -lh target/hd-skill-backend-1.0.0.jar`，应约 50M。

### Step 2: 下载 x86_64 JDK（带缓存）

```bash
cd /root
if [ -f /tmp/jdk17-x64.tar.gz ]; then
  echo "使用JDK缓存"
  cp /tmp/jdk17-x64.tar.gz jdk17-x64.tar.gz
else
  wget -O jdk17-x64.tar.gz "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz"
  cp jdk17-x64.tar.gz /tmp/jdk17-x64.tar.gz
fi
tar -xzf jdk17-x64.tar.gz
# 产出: jdk-17.0.19+10/
```

### Step 3: 提取 CentOS 7 amd64 rootfs

```bash
docker create --name centos-rootfs --platform linux/amd64 \
  swr.cn-north-4.myhuaweicloud.com/library/centos:7 /bin/bash
docker export centos-rootfs > /root/centos7-rootfs.tar
docker rm centos-rootfs
```

### Step 4: 组装 rootfs

```bash
cd /root
rm -rf rootfs && mkdir -p rootfs
cd rootfs
tar -xf ../centos7-rootfs.tar
mkdir -p usr/lib/jvm app tmp
cp -a ../jdk-17.0.19+10 usr/lib/jvm/java-17-openjdk
ln -sf /usr/lib/jvm/java-17-openjdk/bin/java usr/bin/java
cp /root/HDAgentSkillDev/backend/target/hd-skill-backend-1.0.0.jar app/app.jar
```

### Step 5: 导入镜像 + 修正架构 + 设置 ENTRYPOINT

```bash
TAG=$(date +%Y%m%d%H%M%S)
IMAGE_TAG=swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:${TAG}

cd /root
tar -cf rootfs.tar -C rootfs .
docker import rootfs.tar $IMAGE_TAG

# 流式修改 config json：架构 arm64→amd64 + ENTRYPOINT + EXPOSE
docker save $IMAGE_TAG -o /root/image.tar

python3 << 'PYEOF'
import json, tarfile, io

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

docker rmi $IMAGE_TAG 2>/dev/null
docker load -i /root/image-fixed.tar

# 验证
docker inspect $IMAGE_TAG --format='Arch: {{.Architecture}} Entrypoint: {{.Config.Entrypoint}}'
# 期望: Arch: amd64 Entrypoint: [java -jar /app/app.jar]
```

### Step 6: 登录 SWR + 推送镜像

```bash
# 登录 SWR（凭证有时效，每次部署前重新登录）
docker login -u cn-north-4@HST3UQPSE9SU06K4QQ26 \
  -p 6b215814cbb9a6266c14d030c19c02f574aa233273930eeab93774db15db8e07 \
  swr.cn-north-4.myhuaweicloud.com

# 推送镜像
docker push $IMAGE_TAG
```

### Step 7: 更新 CCE Deployment

```bash
CCE_CERTS="--cacert /root/lipeixin/ccecert/ca.crt --cert /root/lipeixin/ccecert/client.crt --key /root/lipeixin/ccecert/client.key"
CCE_API="https://192.168.1.214:5443"

curl -s $CCE_CERTS \
  -X PATCH \
  -H "Content-Type: application/strategic-merge-patch+json" \
  -d "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"hd-skill-backend\",\"image\":\"${IMAGE_TAG}\"}]}}}}" \
  "$CCE_API/apis/apps/v1/namespaces/default/deployments/hd-skill-backend"
```

### Step 8: 验证部署 + 输出报告

```bash
# 等待滚动更新
sleep 30

# Deployment 状态
curl -s $CCE_CERTS \
  "$CCE_API/apis/apps/v1/namespaces/default/deployments/hd-skill-backend" | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][0]
s=d['status']
print(f'镜像: {c[\"image\"]}')
print(f'副本: {s[\"replicas\"]}  就绪: {s.get(\"readyReplicas\",0)}  更新: {s.get(\"updatedReplicas\",0)}')
"

# Pod 状态
curl -s $CCE_CERTS \
  "$CCE_API/api/v1/namespaces/default/pods" | python3 -c "
import sys,json
for p in json.load(sys.stdin)['items']:
    if 'hd-skill-backend' in p['metadata']['name']:
        s=p['status']
        cs=s.get('containerStatuses',[{}])[0]
        print(f'Pod: {p[\"metadata\"][\"name\"]}  状态: {s[\"phase\"]}  IP: {s.get(\"podIP\",\"N/A\")}  重启: {cs.get(\"restartCount\",0)}  就绪: {cs.get(\"ready\",False)}')
"

# Service 访问信息
curl -s $CCE_CERTS \
  "$CCE_API/api/v1/namespaces/default/services" | python3 -c "
import sys,json
for svc in json.load(sys.stdin)['items']:
    name=svc['metadata']['name']
    if 'skill' in name.lower() or 'backend' in name.lower():
        spec=svc['spec']
        ingress=svc['status'].get('loadBalancer',{}).get('ingress',[])
        ext_ip=ingress[0].get('ip','N/A') if ingress else 'N/A'
        ports=', '.join(f\"{p['port']}->{p['targetPort']}\" for p in spec['ports'])
        print(f'Service: {name}  类型: {spec[\"type\"]}  外部IP: {ext_ip}  端口: {ports}')
"
```

## 部署报告模板

完成后输出以下格式的报告：

```text
=== 部署信息 ===

构建:
  项目: /root/HDAgentSkillDev/backend
  JAR: hd-skill-backend-1.0.0.jar
  构建方式: 跨架构 aarch64 → amd64

镜像:
  SWR: swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:<TAG>
  架构: amd64
  ENTRYPOINT: [java -jar /app/app.jar]

CCE:
  Deployment: hd-skill-backend (namespace: default)
  Pod: <pod-name>
  状态: Running
  就绪: 1/1
  重启: 0

访问:
  API: http://192.168.1.21:8080/api/skills
```

## 清理临时文件

```bash
rm -rf /root/rootfs /root/centos7-rootfs.tar /root/rootfs.tar \
       /root/image.tar /root/image-fixed.tar \
       /root/jdk17-x64.tar.gz /root/jdk-17.0.19+10
```

## 陷阱速查

| 问题 | 原因 | 解决 |
|------|------|------|
| `exec format error` | 镜像架构与CCE节点不匹配 | 确保Step5修正架构为amd64 |
| `no command specified` | docker import无ENTRYPOINT | Step5流式修改config json添加ENTRYPOINT |
| Docker Hub不可达 | 华为云网络限制 | 用SWR centos:7 + 清华JDK镜像 |
| JDK下载404 | 华为云repo无JDK17 | 用清华镜像mirrors.tuna.tsinghua.edu.cn |
| tar打包失败 | 解压→修改→重打包不可靠 | 用流式tarfile透传，只改config json |
| CCE PATCH返回非JSON | URL拼接错误或证书问题 | 检查$CCE_API末尾无斜杠，证书路径正确 |
| /tmp空间不足 | docker save约568M | 用/root作工作目录，构建后及时清理 |
| 端口冲突 | 8080已占用 | 不自行调整端口，报告给用户处理 |
| SWR push unauthorized | 登录凭证过期 | 重新执行 docker login 登录 SWR |
| CCE PATCH连接失败 | API地址错误 | 确认CCE地址为192.168.1.214:5443 |
| CCE证书验证失败 | 证书文件缺失/过期 | 确认/root/lipeixin/ccecert/下ca.crt/client.crt/client.key存在 |

## 参考文档

- [华为云 SWR 容器镜像服务](https://support.huaweicloud.com/swr/index.html)
- [华为云 CCE 容器引擎](https://support.huaweicloud.com/cce/index.html)
- [Docker cross-platform build](https://docs.docker.com/build/building/multi-platform/)
- [springboot-docker-packaging 技能 (springboot-docker-packaging)] — 跨架构构建详细步骤
