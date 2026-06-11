#!/bin/bash
# Spring Boot 后端 tar.gz 出包脚本
# 用途：构建 JAR + 生成 install.md + 打包 tar.gz(时间戳精确到秒) + 上传 OBS
# 用法：./package-and-upload.sh <backend_dir> <app_name> [obs_path]
#
# 环境变量(可选):
#   OBS_PATH  - OBS上传路径 (默认: 跳过上传)

set -euo pipefail

BACKEND_DIR="${1:?用法: $0 <backend_dir> <app_name> [obs_path]}"
APP_NAME="${2:?用法: $0 <backend_dir> <app_name> [obs_path]}"
OBS_PATH="${3:-}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
STAGING="/tmp/${APP_NAME}-pkg-$$"

echo "=== Spring Boot 后端打包 ==="
echo "后端目录: $BACKEND_DIR"
echo "应用名称: $APP_NAME"
echo "时间戳: $TIMESTAMP"

# 1. Maven 构建
echo "[1/4] Maven 构建 JAR..."
cd "$BACKEND_DIR"
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}
export PATH=$JAVA_HOME/bin:$PATH
mvn clean package -DskipTests -q

# 查找 JAR
JAR_FILE=$(find target -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -1)
if [ -z "$JAR_FILE" ]; then
    echo "✗ 未找到构建产物 JAR"
    exit 1
fi
JAR_NAME=$(basename "$JAR_FILE")
echo "  产出: $JAR_NAME"

# 2. 生成 install.md
echo "[2/4] 生成 install.md..."
mkdir -p "$STAGING"
cat > "$STAGING/install.md" << INSTALL_EOF
# ${APP_NAME} 安装说明

## 环境要求
- JDK 17+
- MySQL 8.0+

## 安装步骤

1. 解压安装包：
   \`\`\`bash
   tar -xzf ${APP_NAME}-${TIMESTAMP}.tar.gz
   \`\`\`

2. 设置环境变量（根据实际环境填写）：
   \`\`\`bash
   export DB_HOST=<db-host>
   export DB_PORT=3306
   export DB_NAME=<db-name>
   export DB_USER=<db-user>
   export DB_PASSWORD=<your-password>
   export JWT_SECRET=<your-jwt-secret-at-least-32-chars>
   \`\`\`

3. 启动服务：
   \`\`\`bash
   nohup java -jar ${JAR_NAME} > app.log 2>&1 &
   \`\`\`

4. 验证服务：
   \`\`\`bash
   curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/actuator/health
   # 期望返回 200
   \`\`\`

## Docker 部署

\`\`\`bash
docker build -t ${APP_NAME} .
docker run -d -p 8080:8080 \\
  -e DB_HOST=<db-host> \\
  -e DB_PORT=3306 \\
  -e DB_NAME=<db-name> \\
  -e DB_USER=<db-user> \\
  -e DB_PASSWORD=<password> \\
  -e JWT_SECRET=<jwt-secret> \\
  ${APP_NAME}
\`\`\`

## 停止服务

\`\`\`bash
kill \$(pgrep -f '${JAR_NAME}')
\`\`\`
INSTALL_EOF

# 3. 打包 tar.gz
echo "[3/4] 打包 tar.gz..."
PKG_NAME="${APP_NAME}-${TIMESTAMP}.tar.gz"
cp "$JAR_FILE" "$STAGING/"
[ -f "$BACKEND_DIR/Dockerfile" ] && cp "$BACKEND_DIR/Dockerfile" "$STAGING/"
[ -f "$BACKEND_DIR/pom.xml" ] && cp "$BACKEND_DIR/pom.xml" "$STAGING/"

tar -czf "/root/$PKG_NAME" -C "$STAGING" .

# 验证包内容
echo "  包内容:"
tar -tzf "/root/$PKG_NAME" | while read f; do echo "    $f"; done

PKG_SIZE=$(ls -lh "/root/$PKG_NAME" | awk '{print $5}')
echo "  包大小: $PKG_SIZE"
echo "  包路径: /root/$PKG_NAME"

# 4. 上传 OBS
echo "[4/4] 上传 OBS..."
if [ -n "$OBS_PATH" ] && command -v obsutil &>/dev/null; then
    obsutil cp "/root/$PKG_NAME" "$OBS_PATH" -f
    echo "  上传目标: $OBS_PATH"
    echo "  ✓ 上传完成"
else
    echo "  跳过 OBS 上传（未指定路径或 obsutil 未安装）"
fi

# 清理
rm -rf "$STAGING"

echo ""
echo "=== 打包完成 ==="
echo "包名: $PKG_NAME"
echo "路径: /root/$PKG_NAME"
echo "大小: $PKG_SIZE"
