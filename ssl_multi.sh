#!/bin/bash
set -e

if [ $# -lt 1 ]; then
  echo "用法: $0 <domain1> [domain2] [domain3] ..."
  exit 1
fi

DOMAINS=("$@")
COMMON_NAME=${DOMAINS[0]}

echo "生成根 CA、支持多域名证书，域名列表：${DOMAINS[*]}"

# 创建临时配置文件 for SAN
SAN_CONF=$(mktemp)
cat > $SAN_CONF <<EOF
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[dn]
C  = CN
ST = Shanghai
L  = Shanghai
O  = NAS
OU = IT
CN = $COMMON_NAME

[req_ext]
subjectAltName = @alt_names

[alt_names]
EOF

# 写入所有域名（支持通配符）
INDEX=1
for d in "${DOMAINS[@]}"
do
  echo "DNS.$INDEX = $d" >> $SAN_CONF
  INDEX=$((INDEX+1))
done

echo "生成根 CA 私钥和证书..."
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NAS/OU=IT/CN=NasCA"

echo "生成服务器私钥和证书签名请求(CSR)..."
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr -config $SAN_CONF

echo "用根 CA 签发服务器证书，包含 SAN 多域名..."
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -extensions req_ext -extfile $SAN_CONF

echo "生成客户端私钥和证书..."
openssl genrsa -out client.key 4096
openssl req -new -key client.key -out client.csr \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NAS/OU=IT/CN=client1"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 3650

echo "导出客户端 PKCS#12 包，密码为 123456..."
openssl pkcs12 -export -in client.crt -inkey client.key \
  -out client.p12 -name client1 -passout pass:123456

# 删除临时配置文件
rm -f $SAN_CONF

echo "成品列表:"
echo "根CA证书: ca.crt"
echo "服务器证书: server.crt"
echo "服务器私钥: server.key"
echo "客户端证书: client.crt"
echo "客户端私钥: client.key"
echo "客户端P12证书包: client.p12"
echo "全部完成！请使用对应证书部署Nginx并导入客户端P12证书"
