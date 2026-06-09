---
name: obs-upload
description: Upload a local directory to Huawei OBS bucket. Supports two modes - direct upload or build-then-upload. All parameters are provided by the user at invocation time.
triggers:
  - upload to obs
  - deploy to obs
  - obs上传
  - 部署到obs
---

# OBS Directory Upload

Upload a local directory (recursive) to a Huawei OBS bucket. Two modes:

- **Build + Upload**: Provide `PROJECT_PATH`, skill runs `npx vite build` then uploads `PROJECT_PATH/dist`
- **Direct Upload**: Provide `LOCAL_DIR` directly, skip build step

## Parameters

| Parameter | Required | Description | Example |
|-----------|----------|-------------|---------|
| AK | Yes | OBS Access Key ID | `your_access_key_id` |
| SK | Yes | OBS Secret Access Key | `your_secret_access_key` |
| SERVER | Yes | OBS endpoint | `obs.cn-north-4.myhuaweicloud.com` |
| BUCKET | Yes | Bucket name | `obs-hd-dev-static` |
| PROJECT_PATH | No | 项目源码路径，填写则先 `npx vite build` 再上传 | `/home/developer/project` |
| LOCAL_DIR | No | 本地上传目录(绝对路径)，填了 PROJECT_PATH 可留空(自动推导为 dist) | `/home/developer/project/dist` |
| OBS_PREFIX | Yes | OBS key prefix (target path in bucket) | `skills` |

> PROJECT_PATH 和 LOCAL_DIR 至少填一个。都填时 LOCAL_DIR 优先；只填 PROJECT_PATH 时 LOCAL_DIR 自动为 `PROJECT_PATH/dist`。

## Install & Setup (首次使用必须执行)

1. Install the OBS SDK:
   ```
   pip install esdk-obs-python
   ```

2. Run the interactive setup script to configure all parameters:
   ```
   python ~/.hermes/skills/devops/obs-upload/scripts/setup.py
   ```
   The script will prompt for each parameter one by one:
   - AK / SK: 输入后会掩码显示并要求确认
   - SERVER / BUCKET: 有默认值，直接回车可跳过
   - PROJECT_PATH: 可留空(直接上传模式)，填写则进入打包+上传模式
   - LOCAL_DIR: 填了 PROJECT_PATH 可留空(自动推导为 dist)
   - OBS_PREFIX: 必须输入

   Configuration is saved to `~/.hermes/skills/devops/obs-upload/scripts/config.json`.

3. If you need to reconfigure, just run setup.py again — it will detect existing config and ask if you want to overwrite.

## Upload Steps

1. Check if config.json exists. If NOT, tell user to run setup.py first and stop.

2. Run the upload script (it handles build + upload automatically based on config):
   ```
   python ~/.hermes/skills/devops/obs-upload/scripts/obs_upload.py
   ```

   The script will:
   - If PROJECT_PATH is set: run `npx vite build` in PROJECT_PATH, then upload PROJECT_PATH/dist
   - If PROJECT_PATH is empty: upload LOCAL_DIR directly

3. Report the result to the user (success/fail counts).

## Quick Reference

```bash
# 首次安装：配置参数
pip install esdk-obs-python
python ~/.hermes/skills/devops/obs-upload/scripts/setup.py

# 打包 + 上传 (PROJECT_PATH 模式)
python ~/.hermes/skills/devops/obs-upload/scripts/obs_upload.py

# 重新配置
python ~/.hermes/skills/devops/obs-upload/scripts/setup.py
```

## Pitfalls

- LOCAL_DIR must be an absolute path and must exist before running.
- OBS_PREFIX should NOT start with `/` — it's a key prefix, not a filesystem path.
- The `obs` Python package is provided by `esdk-obs-python` (not `obs`).
- Large directories may take time; set terminal timeout accordingly (e.g. 300s).
- AK/SK are saved in config.json in plaintext — keep the skill directory secure.
- Build command is `npx vite build` — only works for Vite projects. For other build tools, modify obs_upload.py.
