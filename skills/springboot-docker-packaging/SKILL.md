---
name: springboot-docker-packaging
description: "Spring Boot 后端 Docker 镜像构建与打包全流程 — 覆盖本地构建、跨架构构建(aarch64→amd64)、SWR推送、CCE部署、tar.gz出包+OBS上传"
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [SpringBoot, Docker, CCE, SWR, HuaweiCloud, CrossArch, Packaging, OBS]
    related_skills: [springboot-vue-nginx-deployment, flask-sqlite-deployment]
---

# Spring Boot 后端 Docker 打包全流程

适用于 HDAgentSkills 项目及类似 Spring Boot 3.x + JDK 17 后端的 Docker 镜像构建、打包、推送与部署。

## 项目参数（HDAgentSkills 为例）

| 参数 | 值 |
|------|-----|
| 后端目录 | /root/HDAgentSkills/backend |
| artifact | hd-skill-backend-1.0.0.jar |
| Spring Boot 版本 | 3.2.5 |
| JDK 版本 | 17 |
| 容器端口 | 8080 |
| SWR 仓库 | swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend |
| CCE 节点架构 | x86_64 (amd64) |
| 构建机器架构 | aarch64 (EulerOS 2.0) |

## 流程一：本地直接 Docker Build（构建机与目标架构相同）

当构建机就是 amd64 时，直接用 Dockerfile 多阶段构建：

### Dockerfile（项目已有）

```dockerfile
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -DskipTests -B

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=builder /app/target/hd-skill-backend-1.0.0.jar app.jar

# 安全：以非root用户运行
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 构建与推送命令

```bash
cd /root/HDAgentSkills/backend

# 1. 构建 Docker 镜像
docker build -t swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest .

# 2. 登录 SWR（需要先获取登录命令，从华为云控制台 → 容器镜像服务 → 登录指令）
# 示例：docker login -u cn-north-4@XXX -p XXXXX swr.cn-north-4.myhuaweicloud.com

# 3. 推送到 SWR
docker push swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest

# 4. 验证
docker inspect swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest --format='{{.Architecture}}'
# 应输出: amd64
```

### 陷阱：Docker Hub 不可达

华为云环境通常无法访问 Docker Hub，`maven:3.9-eclipse-temurin-17` 和 `eclipse-temurin:17-jre-alpine` 基础镜像拉取会失败。解决方案：
- 用 SWR 公共镜像：`swr.cn-north-4.myhuaweicloud.com/library/centos:7`（amd64 可用）
- 或本地已有镜像：`docker images | grep temurin`
- 或提前 `docker pull` + `docker tag` 到本地

## 流程二：跨架构构建（aarch64 构建机 → amd64 CCE 镜像）

**这是 HDAgentSkills 的常见场景**：构建机是 EulerOS 2.0 aarch64，但 CCE 集群节点是 x86_64。

`docker build --platform linux/amd64` 需要 QEMU，EulerOS 上通常不可用。使用 **rootfs 导入 + manifest 修正** 方案：

### 步骤 1：本地 Maven 构建 JAR

```bash
cd /root/HDAgentSkills/backend
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export PATH=$JAVA_HOME/bin:$PATH
mvn clean package -DskipTests
# 产出: target/hd-skill-backend-1.0.0.jar
```

### 步骤 2：下载 x86_64 JDK

```bash
cd /root
wget -O jdk17-x64.tar.gz "https://repo.huaweicloud.com/openjdk/17.0.2/openjdk-17.0.2_linux-x64_bin.tar.gz"
tar -xzf jdk17-x64.tar.gz  # 产出 jdk-17.0.2/
```

### 步骤 3：提取 x86_64 CentOS 7 rootfs

```bash
docker create --name centos-rootfs --platform linux/amd64 \
  swr.cn-north-4.myhuaweicloud.com/library/centos:7 /bin/bash
docker export centos-rootfs > /root/centos7-rootfs.tar
docker rm centos-rootfs
```

**陷阱：SWR 镜像不存在** — `swr.cn-north-4.myhuaweicloud.com/library/centos:7` 是已验证可用的 amd64 镜像。debian/ubuntu/eclipse-temurin 等可能不存在或需授权。

### 步骤 4：组装 rootfs

```bash
cd /root
rm -rf rootfs && mkdir -p rootfs
cd rootfs
tar -xf ../centos7-rootfs.tar

# 安装 JDK
mkdir -p usr/lib/jvm app
cp -a ../jdk-17.0.2 usr/lib/jvm/java-17-openjdk
ln -sf /usr/lib/jvm/java-17-openjdk/bin/java usr/bin/java

# 安装 JAR
cp /root/HDAgentSkills/backend/target/hd-skill-backend-1.0.0.jar app/app.jar

# 确保 /tmp 存在（Tomcat 需要）
mkdir -p tmp
```

### 步骤 5：导入并设置 ENTRYPOINT

```bash
cd /root
tar -cf rootfs.tar -C rootfs .

# 导入镜像
IMAGE_TAG=swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest
docker import rootfs.tar $IMAGE_TAG

# 设置 ENTRYPOINT（docker import 不带 ENTRYPOINT）
docker create --name tmp-entry $IMAGE_TAG java -jar /app/app.jar
docker commit -c 'ENTRYPOINT ["java", "-jar", "/app/app.jar"]' -c 'EXPOSE 8080' tmp-entry $IMAGE_TAG
docker rm tmp-entry
```

### 步骤 6：修正架构标签

`docker commit` 继承宿主机架构标签(arm64)，但内容实际是 amd64。必须修正：

```python
import json, hashlib, os

# 保存镜像
os.system("docker save swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest -o /root/image.tar")

# 解压
os.makedirs("/root/img-fix", exist_ok=True)
os.system("tar -xf /root/image.tar -C /root/img-fix")

# 修正架构标签
for f in os.listdir("/root/img-fix"):
    if f.endswith('.json') and f not in ('manifest.json', 'repositories'):
        path = os.path.join("/root/img-fix", f)
        with open(path) as fh:
            config = json.load(fh)
        if config.get('architecture') == 'arm64':
            config['architecture'] = 'amd64'
            new_content = json.dumps(config)
            new_hash = hashlib.sha256(new_content.encode()).hexdigest()
            os.rename(path, os.path.join("/root/img-fix", f"{new_hash}.json"))
            with open(os.path.join("/root/img-fix", f"{new_hash}.json"), 'w') as fh:
                fh.write(new_content)
            # 更新 manifest.json
            with open("/root/img-fix/manifest.json") as fh:
                manifest = json.load(fh)
            for entry in manifest:
                entry['Config'] = f"{new_hash}.json"
            with open("/root/img-fix/manifest.json", 'w') as fh:
                json.dump(manifest, fh)
            break

# 重新打包并加载
os.system("tar -cf /root/image-fixed.tar -C /root/img-fix .")
os.system("docker load -i /root/image-fixed.tar")

# 验证
os.system("docker inspect swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest --format='{{.Architecture}}'")
# 应输出: amd64
```

### 步骤 7：推送 SWR

```bash
# 登录 SWR（从华为云控制台获取）
docker login -u cn-north-4@XXX -p XXXXX swr.cn-north-4.myhuaweicloud.com

# 推送
docker push swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest
```

## 流程三：tar.gz 出包 + install.md + OBS 上传

适用于非容器化部署（直接 JAR 部署）或交付物归档。

### 步骤 1：构建 JAR

```bash
cd /root/HDAgentSkills/backend
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export PATH=$JAVA_HOME/bin:$PATH
mvn clean package -DskipTests
```

### 步骤 2：生成 install.md

install.md 内容模板：

```markdown
# HD-Skill Backend 安装说明

## 环境要求
- JDK 17+
- MySQL 8.0+

## 安装步骤

1. 解压安装包：
   tar -xzf hd-skill-backend-<timestamp>.tar.gz

2. 设置环境变量：
   export DB_HOST=192.168.1.18
   export DB_PORT=3306
   export DB_NAME=rds-hd-dev-skills-db
   export DB_USER=hdskill_app
   export DB_PASSWORD=<your-password>
   export JWT_SECRET=<your-jwt-secret>
   export ADMIN_USERNAME=admin
   export ADMIN_PASSWORD=<your-admin-password>

3. 启动服务：
   java -jar hd-skill-backend-1.0.0.jar

4. 验证：
   curl http://localhost:8080/api/skills

## Docker 部署

docker build -t hd-skill-backend .
docker run -d -p 8080:8080 \
  -e DB_HOST=... -e DB_PORT=3306 -e DB_NAME=... \
  -e DB_USER=... -e DB_PASSWORD=... \
  -e JWT_SECRET=... -e ADMIN_USERNAME=admin -e ADMIN_PASSWORD=... \
  hd-skill-backend
```

### 步骤 3：打包 tar.gz（时间戳精确到秒）

```bash
TIMESTAMP=$(date +%Y%m%d%H%M%S)
PKG_NAME=hd-skill-backend-${TIMESTAMP}.tar.gz
STAGING=/tmp/hd-skill-backend-pkg

rm -rf $STAGING && mkdir -p $STAGING
cp /root/HDAgentSkills/backend/target/hd-skill-backend-1.0.0.jar $STAGING/
cp /root/HDAgentSkills/backend/Dockerfile $STAGING/
cp /root/HDAgentSkills/backend/pom.xml $STAGING/
# 复制 install.md
cp /tmp/install.md $STAGING/

tar -czf /root/${PKG_NAME} -C $STAGING .

# 验证
tar -tzf /root/${PKG_NAME}
```

### 步骤 4：上传 OBS

```bash
obsutil cp /root/${PKG_NAME} obs://obs-hd-dev-static/vmp-test/ -f
```

**陷阱：obsutil 递归上传(-r -flat=false) 会创建嵌套路径**，单文件上传用 `obsutil cp <file> obs://bucket/path/ -f`。

## 流程四：Docker 镜像本地验证

构建完成后，在本地验证镜像可运行：

```bash
# 使用非冲突端口（如 18080）避免与现有服务冲突
docker run -d --name backend-test -p 18080:8080 \
  -e DB_HOST=192.168.1.18 \
  -e DB_PORT=3306 \
  -e DB_NAME=rds-hd-dev-skills-db \
  -e DB_USER=hdskill_app \
  -e DB_PASSWORD=<password> \
  -e JWT_SECRET=<at-least-32-char-random-string> \
  -e ADMIN_USERNAME=admin \
  -e ADMIN_PASSWORD=<admin-password> \
  swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest

# 等待启动
sleep 15
docker logs backend-test  # 应看到 Spring Boot banner

# 测试 API
curl -s -o /dev/null -w "%{http_code}" http://localhost:18080/api/skills
# 应返回 200 或 401（有 Security 时）

# 清理
docker stop backend-test && docker rm backend-test
```

## CCE 部署 YAML 模板

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hd-skill-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hd-skill-backend
  template:
    metadata:
      labels:
        app: hd-skill-backend
    spec:
      containers:
      - name: hd-skill-backend
        image: swr.cn-north-4.myhuaweicloud.com/swr-hd/hd-skill-backend:latest
        ports:
        - containerPort: 8080
        env:
        - name: DB_HOST
          value: "192.168.1.18"
        - name: DB_PORT
          value: "3306"
        - name: DB_NAME
          value: "rds-hd-dev-skills-db"
        - name: DB_USER
          value: "hdskill_app"
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: hd-skill-secrets
              key: db-password
        - name: JWT_SECRET
          valueFrom:
            secretKeyRef:
              name: hd-skill-secrets
              key: jwt-secret
        - name: ADMIN_USERNAME
          value: "admin"
        - name: ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: hd-skill-secrets
              key: admin-password
        - name: FRONTEND_URL
          value: "http://service-dev.topxtopx.com"
---
apiVersion: v1
kind: Service
metadata:
  name: hd-skill-backend-svc
spec:
  selector:
    app: hd-skill-backend
  ports:
  - port: 8090
    targetPort: 8080
  type: ClusterIP
```

## 环境变量清单

| 变量 | 说明 | 默认值 | 必填 |
|------|------|--------|------|
| DB_HOST | MySQL 主机 | 192.168.1.18 | 是 |
| DB_PORT | MySQL 端口 | 3306 | 否 |
| DB_NAME | 数据库名 | rds-hd-dev-skills-db | 是 |
| DB_USER | 数据库用户 | hdskill_app | 是 |
| DB_PASSWORD | 数据库密码 | (空) | 是 |
| JWT_SECRET | JWT 签名密钥 | (空) | 是 |
| ADMIN_USERNAME | 管理员用户名 | admin | 否 |
| ADMIN_PASSWORD | 管理员密码 | (空) | 是 |
| FRONTEND_URL | 前端地址(CORS) | http://service-dev.topxtopx.com | 否 |
| GITCODE_TOKEN | GitCode API Token | (空) | 否 |
| OBS_AK | OBS Access Key | (空) | 否 |
| OBS_SK | OBS Secret Key | (空) | 否 |
| OBS_SERVER | OBS 服务地址 | https://obs.cn-north-7.ulanqab.huawei.com | 否 |
| OBS_BUCKET | OBS 桶名 | obs-hd-static-cdn-skill-wl203 | 否 |

## 常见错误速查

| 错误 | 原因 | 解决 |
|------|------|------|
| `exec format error` | 镜像架构与 CCE 节点不匹配 | 用跨架构构建流程，确保镜像为 amd64 |
| `no command specified` | docker import 镜像无 ENTRYPOINT | 用 docker commit 添加 ENTRYPOINT |
| `Unable to create tempDir` | 镜像缺少 /tmp 目录 | rootfs 中 mkdir -p tmp |
| Docker Hub pull 失败 | 华为云无法访问 Docker Hub | 用 SWR 公共镜像或本地已有镜像 |
| `architecture: arm64` | docker commit 继承宿主机架构 | 用 manifest 修正流程改为 amd64 |
| Spring Boot 启动失败 | 环境变量未设置 | 导出所有必填环境变量后再启动 |
| MySQL 连接失败 | DB_PASSWORD 为空默认值 | application.yml 中 `${DB_PASSWORD:}` 空默认会导致空密码连接 |
| 端口冲突 | 8080 已被占用 | **不自行调整端口，报告给用户处理** |

## 清理构建临时文件

```bash
rm -rf /root/rootfs /root/centos7-rootfs.tar /root/rootfs.tar /root/image.tar /root/image-fixed.tar /root/img-fix /root/jdk17-x64.tar.gz /root/jdk-17.0.2 /tmp/hd-skill-backend-pkg
```
