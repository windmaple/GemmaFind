#!/usr/bin/env bash
# Creates a local, self-signed code-signing identity in a dedicated keychain.
#
# Why: ad-hoc signed apps are identified by macOS privacy (TCC) by their binary hash,
# which changes on every rebuild, so folder-access grants (Documents, Desktop,
# Downloads) would be asked for again after each build. Signing with a stable
# certificate makes the app's identity (bundle id + certificate) survive rebuilds.
#
# Safe to run repeatedly; it does nothing if the identity already exists.
set -euo pipefail

IDENTITY="GemmaFind Local Signing"
KEYCHAIN="$HOME/Library/Keychains/gemmafind-signing.keychain-db"
KC_PASS="gemmafind"

# codesign only finds identities in keychains on the user search list.
ensure_in_search_list() {
    local current=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # trim leading spaces
        line="${line%\"}"; line="${line#\"}"      # strip quotes
        [ -n "$line" ] && current+=("$line")
    done < <(security list-keychains -d user)
    for k in "${current[@]}"; do
        [ "$k" = "$KEYCHAIN" ] && return 0
    done
    security list-keychains -d user -s "${current[@]}" "$KEYCHAIN"
}

if [ -f "$KEYCHAIN" ] && security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    ensure_in_search_list
    exit 0
fi

echo "🔐 Creating local signing identity \"$IDENTITY\"..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Use the system LibreSSL so the .p12 uses algorithms `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$TMP/id.p12" -passout pass:"$KC_PASS"

[ -f "$KEYCHAIN" ] || security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"           # never auto-lock
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KC_PASS" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
ensure_in_search_list

echo "✅ Signing identity ready (keychain: $KEYCHAIN)"
