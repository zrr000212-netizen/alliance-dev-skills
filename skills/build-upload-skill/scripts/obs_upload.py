#!/usr/bin/env python3
import os
import json
import sys
import subprocess
from obs import ObsClient

# 从同目录 config.json 读取配置
SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'config.json')

if not os.path.exists(SCRIPT_DIR):
    print("错误: 未找到配置文件 config.json")
    print("请先运行 setup.py 配置参数: python scripts/setup.py")
    sys.exit(1)

with open(SCRIPT_DIR, 'r') as f:
    config = json.load(f)

AK = config['AK']
SK = config['SK']
SERVER = config['SERVER']
BUCKET = config['BUCKET']
PROJECT_PATH = config.get('PROJECT_PATH', '')
OBS_PREFIX = config['OBS_PREFIX']

# 确定 LOCAL_DIR
if PROJECT_PATH:
    # 有项目路径 → 先打包，LOCAL_DIR 推导为 项目路径/dist
    LOCAL_DIR = config.get('LOCAL_DIR', '') or os.path.join(PROJECT_PATH, 'dist')
    print(f"项目路径: {PROJECT_PATH}")
    print(f"打包产物目录: {LOCAL_DIR}")
    print()
    print("=" * 50)
    print("  Step 1: 打包项目 (npx vite build)")
    print("=" * 50)
    try:
        result = subprocess.run(
            ['npx', 'vite', 'build'],
            cwd=PROJECT_PATH,
            capture_output=False,
            timeout=300,
        )
        if result.returncode != 0:
            print(f"\n打包失败! exit code: {result.returncode}")
            sys.exit(1)
        print("\n打包成功!")
    except FileNotFoundError:
        print("错误: 找不到 npx，请确认 Node.js 已安装")
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("错误: 打包超时 (300s)")
        sys.exit(1)
else:
    # 无项目路径 → 直接使用 LOCAL_DIR
    LOCAL_DIR = config.get('LOCAL_DIR', '')
    if not LOCAL_DIR:
        print("错误: PROJECT_PATH 和 LOCAL_DIR 都为空，无法确定上传目录")
        sys.exit(1)

# 验证 LOCAL_DIR 存在
if not os.path.isdir(LOCAL_DIR):
    print(f"错误: 上传目录不存在: {LOCAL_DIR}")
    sys.exit(1)

print()
print("=" * 50)
print("  Step 2: 上传到 OBS")
print("=" * 50)
print(f"本地目录: {LOCAL_DIR}")
print(f"目标: obs://{BUCKET}/{OBS_PREFIX}/")
print()

obsClient = ObsClient(access_key_id=AK, secret_access_key=SK, server=SERVER)

def upload_dir(local_dir, obs_prefix):
    success = 0
    fail = 0
    for root, dirs, files in os.walk(local_dir):
        for f in files:
            local_path = os.path.join(root, f)
            rel_path = os.path.relpath(local_path, local_dir)
            obs_key = obs_prefix + '/' + rel_path.replace(os.sep, '/')

            print(f"Uploading: {local_path} -> obs://{BUCKET}/{obs_key}")
            try:
                resp = obsClient.putFile(BUCKET, obs_key, local_path)
                if resp.status >= 200 and resp.status < 300:
                    print(f"  OK (status={resp.status})")
                    success += 1
                else:
                    print(f"  FAIL (status={resp.status}, reason={resp.reason})")
                    fail += 1
            except Exception as e:
                print(f"  ERROR: {e}")
                fail += 1

    return success, fail

try:
    success, fail = upload_dir(LOCAL_DIR, OBS_PREFIX)
    print(f"\nDone! Success: {success}, Failed: {fail}")
finally:
    obsClient.close()
