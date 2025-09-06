#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "用法: $0 <domain>"
  exit 1
fi

DOMAIN=$1

echo "生成针对域名 $DOMAIN 的证书..."

# 生成根 CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NAS/OU=IT/CN=NasCA"

# 生成服务器证书
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NAS/OU=IT/CN=$DOMAIN"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650

# 生成客户端证书，CN固定为client1，也可修改为参数
openssl genrsa -out client.key 4096
openssl req -new -key client.key -out client.csr \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=NAS/OU=IT/CN=client1"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 3650

# 导出客户端PKCS#12证书包，密码为123456
openssl pkcs12 -export -in client.crt -inkey client.key \
  -out client.p12 -name client1 -passout pass:123456

echo "根CA证书: ca.crt"
echo "服务器证书: server.crt"
echo "服务器私钥: server.key"
echo "客户端证书: client.crt"
echo "客户端私钥: client.key"
echo "客户端P12证书包: client.p12"
echo "全部生成完成！"
