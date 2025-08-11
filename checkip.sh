#!/bin/bash
 
# 配置参数 
GATEWAY="192.168.1.1"           # 路由器网关IP 
NUC_IP="192.168.1.253"          # 本机IP地址 
BARK_KEY="XXXXXXXXXXXXXXXxxxx"  # Bark通知密钥 
CHECK_INTERVAL=15               # 检测间隔(秒)
MAX_FAILED_PINGS=5              # 连续失败次数阈值 
MAX_NIC_RESETS=2                # 最大网卡重启次数 
NETWORK_INTERFACE="eno1"        # 网络接口名称 
LOG_FILE="/home/app/checkip/log/network_monitor.log"   # 日志文件路径 
 
# 创建日志目录和文件
mkdir -p $(dirname "$LOG_FILE")
touch "$LOG_FILE"
 
# 日志记录函数
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}
 
# 发送Bark通知 
send_notification() {
    local title="PVE网络监控通知"
    local message="$1"
    curl -s "https://api.day.app/$BARK_KEY/$title/$message"  > /dev/null 2>&1
    log "已发送通知: $message"
}
 
# 重启网络接口
reset_network_interface() {
    log "尝试重启网络接口 $NETWORK_INTERFACE..."
    ifdown $NETWORK_INTERFACE && ifup $NETWORK_INTERFACE
    if [ $? -eq 0 ]; then
        log "网络接口 $NETWORK_INTERFACE 重启成功"
        return 0
    else 
        log "网络接口 $NETWORK_INTERFACE 重启失败"
        return 1 
    fi
}
 
# 主监控循环
nic_reset_count=0
while true; do 
    # 检查网关连通性
    failed_pings=0 
    for ((i=1; i<=MAX_FAILED_PINGS; i++)); do
        if ! ping -c 1 -W 1 $GATEWAY > /dev/null 2>&1; then 
            failed_pings=$((failed_pings + 1))
            log "第 $i 次ping网关 $GATEWAY 失败 (累计失败 $failed_pings 次)"
        else
            # 如果有一次成功就跳出循环
            break 
        fi
        sleep 1 
    done 
 
    # 如果连续失败达到阈值
    if [ $failed_pings -ge $MAX_FAILED_PINGS ]; then 
        log "检测到网络连接问题: 连续 $failed_pings 次ping网关失败"
        
        # 尝试重启网络接口
        if [ $nic_reset_count -lt $MAX_NIC_RESETS ]; then
            reset_network_interface 
            if [ $? -eq 0 ]; then
                nic_reset_count=$((nic_reset_count + 1))
                send_notification "网络异常已自动重启网卡$NETWORK_INFACE ($nic_reset_count/$MAX_NIC_RESETS)"
                
                # 等待网络恢复 
                sleep 10
                continue 
            fi 
        else
            # 达到最大重启次数后重启系统 
            log "已达到最大网卡重启次数($MAX_NIC_RESETS)，将重启系统..."
            send_notification "网络恢复失败，即将重启系统"
            reboot 
            exit 0 
        fi
    else 
        # 网络正常时重置计数器
        if [ $nic_reset_count -gt 0 ]; then 
            log "网络已恢复，重置网卡重启计数器"
            nic_reset_count=0 
            send_notification "网络连接已恢复正常 Good Lucky SIR !!!"
        fi
    fi 
    
    sleep $CHECK_INTERVAL
done
