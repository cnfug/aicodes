import requests
import os
import sys
import time
import json
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
from tqdm import tqdm
from urllib.parse import urlparse

# 禁用安全警告
requests.packages.urllib3.disable_warnings()

# --- 配置区 ---
MAX_WORKERS = 10            
ROOT_SAVE_PATH = "/home/alist/"  
MAX_RETRIES = 3            
ONLY_EXTENSIONS = [] 
#  ".ipa", ".exe" 只下载以上文件名

EXCLUDE_LIST = [
    "@eaDir", "#recycle", ".DS_Store", "System Volume Information", 
    "Games", "Game", "game", "游戏", "Apple Arcade", "Arcade", "temp"
]
# --------------

def write_log(log_path, data):
    """[新增] 将同步记录写入 JSON 文件"""
    log_file = os.path.join(log_path, "sync_history.json")
    record = {
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        **data
    }
    # 采用追加模式写入（每行一个 JSON 对象，方便大文件读取）
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")

def get_file_list(base_url, path):
    api_url = f"{base_url.rstrip('/')}/api/fs/list"
    payload = {"path": path, "page": 1, "per_page": 0}
    try:
        r = requests.post(api_url, json=payload, timeout=15, verify=False)
        data = r.json()
        if data['code'] != 200: return [], []
        content = data['data']['content']
        return [x for x in content if x['is_dir']], [x for x in content if not x['is_dir']]
    except: return [], []

def get_download_url(base_url, path):
    api_url = f"{base_url.rstrip('/')}/api/fs/get"
    try:
        r = requests.post(api_url, json={"path": path}, timeout=15, verify=False)
        return r.json()['data']['raw_url'] if r.json()['code'] == 200 else None
    except: return None

def download_file(base_url, f_path, f_local, remote_size, current_log_root):
    if ONLY_EXTENSIONS and not any(f_path.lower().endswith(ext) for ext in ONLY_EXTENSIONS):
        return

    filename = os.path.basename(f_local)
    local_size = os.path.getsize(f_local) if os.path.exists(f_local) else 0
    
    # --- 1. 跳过显示逻辑 [增强] ---
    if remote_size > 0 and local_size == remote_size:
        tqdm.write(f"✅ [Skip] {filename}") # 使用 tqdm.write 避免破坏其他进度条
        write_log(current_log_root, {"name": filename, "status": "skipped", "size": remote_size})
        return

    # --- 2. 下载与重试逻辑 ---
    for attempt in range(MAX_RETRIES):
        url = get_download_url(base_url, f_path)
        if not url: continue

        headers = {"User-Agent": "Mozilla/5.0", "Range": f"bytes={local_size}-"}
        mode = 'ab' if local_size > 0 else 'wb'
        
        try:
            r = requests.get(url, stream=True, headers=headers, verify=False, timeout=30)
            pbar = tqdm(total=remote_size, initial=local_size, unit='B', unit_scale=True, 
                        desc=f"📥 {filename[:20]}", leave=False)

            with open(f_local, mode) as f:
                for chunk in r.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        f.write(chunk)
                        pbar.update(len(chunk))
            pbar.close()
            
            write_log(current_log_root, {"name": filename, "status": "success", "size": remote_size})
            return 
        except Exception as e:
            if attempt == MAX_RETRIES - 1:
                tqdm.write(f"❌ 失败: {filename} -> {e}")
                write_log(current_log_root, {"name": filename, "status": "error", "msg": str(e)})
            else:
                time.sleep(2)

def recursive_scan(base_url, path, executor, current_save_path):
    if any(ex.lower() in path.lower() for ex in EXCLUDE_LIST):
        return

    local_dir = os.path.join(current_save_path, path.strip("/"))
    if not os.path.exists(local_dir): os.makedirs(local_dir, exist_ok=True)
    
    dirs, files = get_file_list(base_url, path)
    
    for f in files:
        if any(ex.lower() in f['name'].lower() for ex in EXCLUDE_LIST):
            continue
            
        full_remote_path = os.path.join(path, f['name']).replace("\\", "/")
        full_local_path = os.path.join(local_dir, f['name'])
        # 传递根路径用于记录日志
        executor.submit(download_file, base_url, full_remote_path, full_local_path, f.get('size', 0), current_save_path)
    
    for d in dirs:
        d_path = os.path.join(path, d['name']).replace("\\", "/")
        recursive_scan(base_url, d_path, executor, current_save_path)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 Final-WithLog.py <Alist_URL>")
        sys.exit(1)
    
    input_url = sys.argv[1]
    domain = urlparse(input_url).netloc or urlparse(f"http://{input_url}").netloc
    BASE_SAVE_PATH = os.path.join(ROOT_SAVE_PATH, domain)
    
    print(f"🚀 启动同步任务 | 日志记录已开启")
    
    if not os.path.exists(BASE_SAVE_PATH):
        os.makedirs(BASE_SAVE_PATH, exist_ok=True)
        
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        recursive_scan(input_url, "/", executor, BASE_SAVE_PATH)
        
    print(f"\n🎉 任务处理完成！日志保存在: {os.path.join(BASE_SAVE_PATH, 'sync_history.json')}")
