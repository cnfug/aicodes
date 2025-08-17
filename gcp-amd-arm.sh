#!/bin/bash
# =============================================================================
# GCP 多区域虚拟机AMD/ARM平台检测脚本
# ----------------------------------------------------------------------------- 
# - 支持多个区域及多个虚拟机
# - 检测到任意AMD或ARM虚拟机后通知
# - 发送Bark通知
# - 统一停止非AMD/ARM虚拟机
# =============================================================================

#项目ID，登录后台查看
PROJECT_ID="flash-xxxxx"

# 多区域配置,需要刷的区域，也可以单区域刷，删除多余即可,us-west区域对国内延迟较低
ZONES=("us-west1-a" "us-west1-b" "us-west1-c")
#对应上面的区域，不需要就删除或者注释掉
declare -A VM_INSTANCES
VM_INSTANCES["us-west1-a"]="west-1a-01 west-1a-02"
VM_INSTANCES["us-west1-b"]="west-1b-01 west-1b-02"
VM_INSTANCES["us-west1-c"]="west-1c-01 west-1c-02"

BARK_SERVER="https://api.day.app"
#设备KEY
BARK_KEY="2V3Wx8XXXXXXXX" 
BARK_TITLE="GCP虚拟机平台检测"

WAIT_SECONDS=30
MAX_ATTEMPTS=999999999
LOG_FILE="./amd_arm_check.log"
LOCK_FILE="/tmp/amd_arm_check_log.lock"
FLAG_FILE="/tmp/platform_detected.flag"
MAX_PARALLEL=1
GOOD_VM_LIST="./good_vms_list.txt"  # 记录符合条件虚拟机的文件路径

print_info()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [信息] $1"; }
print_success()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [成功] $1"; }
print_warning()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [警告] $1"; }

send_bark_notification() {
  local message="$1"
  curl -s "${BARK_SERVER}/${BARK_KEY}/${BARK_TITLE}/${message}?group=platform-detector" > /dev/null
}

log_message() {
  local msg="$1"
  (
    flock 200
    echo "$msg" >> "$LOG_FILE"
  ) 200>"$LOCK_FILE"
}

if [[ "$PROJECT_ID" == "your-gcp-project-id" ]]; then
  echo "错误：请先编辑脚本配置项 PROJECT_ID"
  exit 1
fi

print_info "设置 GCP 项目: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" > /dev/null

# 清理标志文件和日志
rm -f "$FLAG_FILE"
touch "$LOG_FILE"

DETECTED_GOOD_VMS=()

job_control() {
  while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do
    sleep 2
  done
}

check_vm() {
  local INSTANCE_NAME=$1
  local ZONE=$2
  local attempt_counter=1

  while [[ $attempt_counter -le $MAX_ATTEMPTS ]]; do
    if [[ -f "$FLAG_FILE" ]]; then
      print_info "检测到标志文件，跳过虚拟机 $INSTANCE_NAME ($ZONE)"
      return
    fi

    print_info "检查虚拟机 $INSTANCE_NAME ($ZONE) (第 $attempt_counter 次尝试)"

    INSTANCE_STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format='value(status)' 2>/dev/null)
    print_info "虚拟机 $INSTANCE_NAME ($ZONE) 当前状态: ${INSTANCE_STATUS:-未知}"

    if [[ "$INSTANCE_STATUS" != "TERMINATED" ]]; then
      print_warning "虚拟机 $INSTANCE_NAME ($ZONE) 不是 TERMINATED 状态，尝试强制关闭"
      gcloud compute instances stop "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null
      sleep 2
    fi

    print_info "启动虚拟机 $INSTANCE_NAME ($ZONE)"
    gcloud compute instances start "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null

    print_info "等待虚拟机 $INSTANCE_NAME ($ZONE) 状态变为 RUNNING..."
    for i in {1..12}; do
      sleep 2
      STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format='value(status)' 2>/dev/null)
      if [[ "$STATUS" == "RUNNING" ]]; then
        print_info "虚拟机 $INSTANCE_NAME ($ZONE) 状态：RUNNING"
        break
      fi
    done

    print_info "等待 $WAIT_SECONDS 秒后检查 $INSTANCE_NAME ($ZONE) 的 CPU平台..."
    sleep $WAIT_SECONDS

    CPU_PLATFORM=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format='value(cpuPlatform)' 2>/dev/null)
    log_message "$(date '+%Y-%m-%d %H:%M:%S') Instance: $INSTANCE_NAME ($ZONE) Attempt #$attempt_counter: CPU = $CPU_PLATFORM"

    if [[ "$CPU_PLATFORM" == "AMD Rome" || "$CPU_PLATFORM" == "AMD Milan" || "$CPU_PLATFORM" == "Ampere" ]]; then
      print_success "虚拟机 $INSTANCE_NAME ($ZONE) 检测到可接受平台: $CPU_PLATFORM"
      touch "$FLAG_FILE"
      send_bark_notification "✅ 成功！$INSTANCE_NAME ($ZONE) 运行在 $CPU_PLATFORM"
      DETECTED_GOOD_VMS+=("$INSTANCE_NAME:$ZONE")
      
      # 将合格虚拟机记录到文件中
      echo "$INSTANCE_NAME:$ZONE" >> "$GOOD_VM_LIST"
      
      return
    else
      print_warning "虚拟机 $INSTANCE_NAME ($ZONE) 当前 CPU 平台: $CPU_PLATFORM，不是 AMD / ARM，将重试"
      print_info "关闭虚拟机 $INSTANCE_NAME ($ZONE)..."
      gcloud compute instances stop "$INSTANCE_NAME" --zone="$ZONE" --quiet 2>/dev/null
      sleep 30
      ((attempt_counter++))
    fi
  done

  print_warning "虚拟机 $INSTANCE_NAME ($ZONE) 已尝试 $MAX_ATTEMPTS 次，未检测到平台，终止该虚拟机"
}

print_info "开始多区域虚拟机平台检测..."

for zone in "${ZONES[@]}"; do
  for INSTANCE_NAME in ${VM_INSTANCES[$zone]}; do
    job_control
    check_vm "$INSTANCE_NAME" "$zone" &
  done
done

wait

print_info "检测完成。开始停止不符合条件的虚拟机..."

for zone in "${ZONES[@]}"; do
  for vm in ${VM_INSTANCES[$zone]}; do
    # 判断该虚拟机是否符合条件
    if grep -q "$vm:$zone" "$GOOD_VM_LIST"; then
      print_info "虚拟机 $vm ($zone) 符合 AMD / ARM 平台，跳过停止"
    else
      print_info "停止虚拟机 $vm ($zone)，该虚拟机不符合 AMD / ARM 平台"
      gcloud compute instances stop "$vm" --zone="$zone" --quiet 2>/dev/null
    fi
  done
done

print_success "所有不符合 AMD / ARM 平台的虚拟机已停止。"
print_info "所有虚拟机检测任务完成。"
