#!/bin/bash
# 日期：2025-09-07 
# 功能：全自动生成根CA+多域名SAN证书，支持简化KEY_USAGE配置多个常见用途
set -eo pipefail
trap 'cleanup' EXIT ERR

# --------------------- 用户配置区（可修改）---------------------
DAYS=${DAYS:-3650}               # 证书有效期（默认3650天，约10年）
COUNTRY=${COUNTRY:-CN}           # 国家代码
STATE=${STATE:-Shanghai}         # 省份
LOCALITY=${LOCALITY:-Shanghai}   # 城市
ORG=${ORG:-MyCompany}            # 组织名称
OU=${OU:-IT}                    # 部门
CA_CN=${CA_CN:-MyRootCA}         # 根CA名称
CLIENT_CN=${CLIENT_CN:-secure-client}  # 客户端证书名称

# KEY_USAGE用途类型（简写）,可选值：
# web       - Web服务器TLS认证（数字签名+密钥加密，服务器认证）
# email     - 邮件加密保护（数字签名，邮件保护）
# client    - 客户端认证（数字签名，客户端身份认证）
# code      - 代码签名（数字签名，代码签名）
# timestamp - 时间戳签名（签名，时间戳）
# ocsp      - OCSP签名（签名，在线证书状态协议）
KEY_USAGE=${KEY_USAGE:-web}
# -------------------------------------------------------------

cleanup() {
  rm -f "$SAN_CONF" "$CLIENT_EXT_CONF" ca.srl client.srl temp_san.conf 2>/dev/null
  log "临时文件已清理"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a certs.log
}

# 根据 KEY_USAGE 映射不同用途的keyUsage和extendedKeyUsage
case "$KEY_USAGE" in
  web)
    SERVER_KEY_USAGE="digitalSignature,keyEncipherment"
    SERVER_EXTENDED_KEY_USAGE="serverAuth"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="clientAuth"
    ;;
  email)
    SERVER_KEY_USAGE="digitalSignature"
    SERVER_EXTENDED_KEY_USAGE="emailProtection"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="emailProtection"
    ;;
  client)
    SERVER_KEY_USAGE="digitalSignature,keyEncipherment"
    SERVER_EXTENDED_KEY_USAGE="serverAuth"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="clientAuth"
    ;;
  code)
    SERVER_KEY_USAGE="digitalSignature"
    SERVER_EXTENDED_KEY_USAGE="codeSigning"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="codeSigning"
    ;;
  timestamp)
    SERVER_KEY_USAGE="digitalSignature"
    SERVER_EXTENDED_KEY_USAGE="timeStamping"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="timeStamping"
    ;;
  ocsp)
    SERVER_KEY_USAGE="digitalSignature"
    SERVER_EXTENDED_KEY_USAGE="OCSPSigning"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="OCSPSigning"
    ;;
  *)
    # 默认web配置
    SERVER_KEY_USAGE="digitalSignature,keyEncipherment"
    SERVER_EXTENDED_KEY_USAGE="serverAuth"
    CLIENT_KEY_USAGE="digitalSignature"
    CLIENT_EXTENDED_KEY_USAGE="clientAuth"
    ;;
esac

generate_san_config() {
  local conf_file="$1"
  shift
  local domains=("$@")

  cat > "$conf_file" <<EOF
[req_ext]
subjectAltName = @alt_names
keyUsage = $SERVER_KEY_USAGE
extendedKeyUsage = $SERVER_EXTENDED_KEY_USAGE
[alt_names]
$(for ((i=0; i < ${#domains[@]}; i++)); do echo "DNS.$((i+1)) = ${domains[i]}"; done)
EOF
}

generate_client_ext_config() {
  local conf_file="$1"

  cat > "$conf_file" <<EOF
[client_ext]
keyUsage = $CLIENT_KEY_USAGE
extendedKeyUsage = $CLIENT_EXTENDED_KEY_USAGE
EOF
}

main() {
  [[ $# -lt 1 ]] && {
    echo "用法: $0 [-c 客户端名称] <域名1> [域名2...]"
    echo "示例: $0 -c 'my-client' '*.nas.yt' 'nas.yt'"
    exit 1
  }

  while getopts ":c:" opt; do
    case $opt in
      c) CLIENT_CN="$OPTARG" ;;
      *) echo "无效选项: -$OPTARG" >&2; exit 1 ;;
    esac
  done
  shift $((OPTIND-1))

  for dom in "$@"; do
    [[ "$dom" =~ ^(\*\.)?[a-zA-Z0-9.-]+$ ]] || {
      log "错误: 非法域名格式 '$dom'"
      exit 1
    }
  done

  DOMAINS=("$@")
  COMMON_NAME="${DOMAINS[0]}"
  SAN_CONF=$(mktemp)
  generate_san_config "$SAN_CONF" "${DOMAINS[@]}"

  CLIENT_EXT_CONF=$(mktemp)
  generate_client_ext_config "$CLIENT_EXT_CONF"

  SERIAL_FILE="ca.srl"

  log "===== 开始生成证书 ====="

  CA_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^')
  openssl genrsa -aes256 -passout pass:"$CA_PASS" -out ca.key 4096
  openssl req -x509 -new -key ca.key -passin pass:"$CA_PASS" -days "$DAYS" \
    -out ca.crt -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/OU=$OU/CN=$CA_CN"

  openssl genrsa -out server.key 4096

  TEMP_CONF=$(mktemp)
  cat > "$TEMP_CONF" <<EOF
[req]
distinguished_name = dn
req_extensions = req_ext
prompt = no
[dn]
CN = $COMMON_NAME
$(cat "$SAN_CONF")
EOF

  openssl req -new -key server.key -out server.csr -config "$TEMP_CONF"
  rm -f "$TEMP_CONF"

  if [ ! -f "$SERIAL_FILE" ]; then
    SERIAL_OPTION="-CAcreateserial"
  else
    SERIAL_OPTION="-CAserial $SERIAL_FILE"
  fi

  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -passin pass:"$CA_PASS" \
    $SERIAL_OPTION -out server.crt -days "$DAYS" -extfile "$SAN_CONF" -extensions req_ext

  CLIENT_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9!@#$%^')
  openssl genrsa -out client.key 4096
  openssl req -new -key client.key -out client.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/OU=$OU/CN=$CLIENT_CN"

  if [ ! -f "$SERIAL_FILE" ]; then
    SERIAL_OPTION="-CAcreateserial"
  else
    SERIAL_OPTION="-CAserial $SERIAL_FILE"
  fi

  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -passin pass:"$CA_PASS" \
    $SERIAL_OPTION -out client.crt -days "$DAYS" -extfile "$CLIENT_EXT_CONF" -extensions client_ext

  openssl pkcs12 -export -in client.crt -inkey client.key \
    -out client.p12 -name "$CLIENT_CN" -passout pass:"$CLIENT_PASS"

  chmod 400 ca.key server.key client.key

  log "===== 证书生成成功 ====="
  {
    echo "根CA证书: ca.crt"
    echo "服务器证书: server.crt  (包含域名: ${DOMAINS[*]})"
    echo "客户端证书: client.p12 (密码: $CLIENT_PASS)"
    echo "证书用途 KEY_USAGE: $KEY_USAGE"
    case "$KEY_USAGE" in
      web) echo "用途说明：Web服务器TLS认证" ;;
      email) echo "用途说明：邮件加密保护" ;;
      client) echo "用途说明：客户端身份认证" ;;
      code) echo "用途说明：代码签名" ;;
      timestamp) echo "用途说明：时间戳服务" ;;
      ocsp) echo "用途说明：OCSP签名" ;;
      *) echo "用途说明：未知（默认Web服务器TLS认证）" ;;
    esac
    echo "执行命令: $0 $@"
  } | tee -a certs.log
}

main "$@"
