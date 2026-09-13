#!/bin/bash
# 一次性创建自签代码签名证书(#50):给 make-app.sh 一个跨构建稳定的签名身份。
#
# 为什么:ad-hoc 签名的身份锚是 cdhash,任何代码改动重打包都会漂移——
# 钥匙串条目 ACL 视每次构建为「新 App」,首启读凭据就弹 login keychain 密码框。
# 自签证书把身份锚固定在证书上,「始终允许」一次即永久。
#
# 用法:scripts/make-signing-cert.sh(幂等:身份已存在则直接退出)
# 注意:`security add-trusted-cert` 可能弹一次系统授权框,一次性成本。
# CN 用 ASCII:openssl -subj 写中文 CN 会按字节错编码成乱码(实测),签名功能虽不受影响,
# 但 find-identity / make-app.sh 按名匹配会落空。
set -euo pipefail

NAME="UsageMonitor-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 幂等:同名有效身份已存在则不重复创建。
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "已存在代码签名身份 \"$NAME\",无需创建。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 自签证书:EKU=codeSigning、非 CA、仅数字签名;十年期(本地开发身份,不用于分发)。
openssl req -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -x509 -days 3650 -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

# 私钥 + 证书合并导入(-T 免 codesign 使用私钥时再弹一次授权)。
cat "$WORK/key.pem" "$WORK/cert.pem" > "$WORK/identity.pem"
security import "$WORK/identity.pem" -k "$KEYCHAIN" -T /usr/bin/codesign

# 用户域信任(非 admin 域;可能弹一次系统授权框)。
# 信任后 `security find-identity -v -p codesigning` 才会列出该身份,make-app.sh 靠它发现。
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "已创建并信任代码签名身份 \"$NAME\"。"
echo "之后 scripts/make-app.sh 会自动改用该身份签名;首次读取既有凭据时点「始终允许」一次即永久。"
