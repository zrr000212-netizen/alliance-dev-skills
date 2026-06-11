# JDK x86_64 镜像源可用性实测

实测时间：2026-05-11，环境：华为云 EulerOS 2.0 aarch64

## 可用

| 源 | URL | 说明 |
|------|-----|------|
| 清华镜像 | `https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz` | **首选**，184MB，下载速度~670KB/s |

## 不可用

| 源 | URL | 失败原因 |
|------|-----|---------|
| 华为云 repo.huaweicloud.com | `https://repo.huaweicloud.com/java/jdk/17.0.2+9/openjdk-17.0.2_linux-x64_bin.tar.gz` | 404，该仓库只有JDK 8 |
| 华为云 Adoptium | `https://mirrors.huaweicloud.com/Adoptium/17/jdk/x64/linux/...` | 返回HTML页面（网页浏览界面），非直接下载 |
| 腾讯云 Adoptium | `https://mirrors.cloud.tencent.com/Adoptium/17/jdk/x64/linux/...` | 同上，返回HTML页面 |
| GitHub Adoptium | `https://github.com/adoptium/temurin17-binaries/releases/download/...` | 网络不通（Docker Hub同理） |
| Adoptium API | `https://api.adoptium.net/v3/binary/latest/17/hotspot/x64/linux/jdk` | 返回 "Resource not found" |

## 建议

- **默认使用清华镜像**，URL稳定、直连下载、无需认证
- 版本号可能随时间更新，可先 `curl -s https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/ | grep -oP 'href="[^"]*\.tar\.gz"'` 查看最新版本
- 如清华镜像也不可访问，可尝试将JDK包预先上传到华为云OBS，从OBS下载
