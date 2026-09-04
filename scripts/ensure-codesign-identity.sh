#!/usr/bin/env bash
# Ensures a stable local code-signing identity so macOS TCC
# (Accessibility / Input Monitoring / Screen Recording) survives rebuilds.
# Ad-hoc signing (codesign -s -) changes CDHash every build and resets TCC.
# Self-signed cert WITHOUT trust may also fail TCC matching — we mark it
# trusted for Code Signing in the login keychain.
set -euo pipefail

CERT_NAME="${ALWM_SIGN_NAME:-ALWM Local Signing}"
SIGN_DIR="${HOME}/.config/alwm/signing"
P12_PATH="${SIGN_DIR}/alwm-local.p12"
P12_PASS="${ALWM_SIGN_P12_PASS:-alwm-local-codesign}"
HASH_PATH="${SIGN_DIR}/identity.sha1"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
if [[ ! -f "$KEYCHAIN" ]]; then
  KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

# Print SHA-1 of matching identity (valid OR present-but-untrusted).
find_identity_hash() {
  security find-identity -p codesigning 2>/dev/null \
    | grep -F "$CERT_NAME" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]+)[[:space:]].*/\1/'
}

identity_exists() {
  [[ -n "$(find_identity_hash)" ]]
}

identity_trusted() {
  # "Valid identities only" list includes trusted code-signing certs.
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$CERT_NAME" \
    | grep -qv 'CSSMERR_TP_NOT_TRUSTED'
}

import_p12() {
  local p12="$1"
  security unlock-keychain "$KEYCHAIN" 2>/dev/null || true
  if ! security import "$p12" \
      -k "$KEYCHAIN" \
      -P "$P12_PASS" \
      -A \
      -T /usr/bin/codesign \
      -T /usr/bin/security 2>/tmp/alwm-security-import.err
  then
    # Already imported is fine.
    if grep -qi "already exists\|duplicate" /tmp/alwm-security-import.err 2>/dev/null; then
      return 0
    fi
    echo "security import failed:" >&2
    cat /tmp/alwm-security-import.err >&2 || true
    return 1
  fi
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "" \
    "$KEYCHAIN" >/dev/null 2>&1 || true
  return 0
}

# Mark the local cert as trusted for Code Signing so TCC keeps grants across rebuilds.
ensure_codesign_trust() {
  if identity_trusted; then
    return 0
  fi

  local tmp
  tmp="$(mktemp -d)"

  cleanup() { rm -rf "$tmp"; }
  if ! security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" >"$tmp/cert.pem" 2>/dev/null; then
    echo "warning: could not export '$CERT_NAME' for trust settings" >&2
    cleanup
    return 1
  fi

  echo "Trusting '$CERT_NAME' for Code Signing (one-time; may ask for your password)…" >&2
  local ok=0
  if security add-trusted-cert \
      -r trustRoot \
      -p codeSign \
      -k "$KEYCHAIN" \
      "$tmp/cert.pem" 2>"$tmp/trust.err"
  then
    ok=1
  elif security add-trusted-cert \
      -r unrestricted \
      -p codeSign \
      -k "$KEYCHAIN" \
      "$tmp/cert.pem" 2>"$tmp/trust.err"
  then
    ok=1
  fi

  if [[ "$ok" -ne 1 ]]; then
    echo "warning: auto-trust failed — set Trust manually:" >&2
    echo "  Keychain Access → '$CERT_NAME' → Trust → Code Signing = Always Trust" >&2
    cat "$tmp/trust.err" >&2 || true
    cleanup
    return 1
  fi

  cleanup
  if identity_trusted; then
    echo "Code Signing trust OK for '$CERT_NAME'." >&2
    return 0
  fi
  echo "warning: cert still listed as not trusted; TCC may reset after rebuilds until you Always Trust it." >&2
  return 1
}

generate_p12() {
  mkdir -p "$SIGN_DIR"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  openssl genrsa -out "$tmp/key.pem" 2048 2>/dev/null
  openssl req -new -key "$tmp/key.pem" -out "$tmp/csr.pem" \
    -subj "/CN=${CERT_NAME}/O=ALWM/OU=Local/C=BR" 2>/dev/null

  cat >"$tmp/ext.cnf" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

  openssl x509 -req -in "$tmp/csr.pem" -signkey "$tmp/key.pem" \
    -out "$tmp/cert.pem" -days 3650 -extfile "$tmp/ext.cnf" 2>/dev/null

  # macOS rejects OpenSSL 3 default PBES2 PKCS#12 — use legacy bags.
  local export_ok=0
  if openssl pkcs12 -export \
      -out "$P12_PATH" \
      -inkey "$tmp/key.pem" \
      -in "$tmp/cert.pem" \
      -passout "pass:${P12_PASS}" \
      -name "$CERT_NAME" \
      -certpbe PBE-SHA1-3DES \
      -keypbe PBE-SHA1-3DES \
      -macalg SHA1 2>/dev/null
  then
    export_ok=1
  elif openssl pkcs12 -export -legacy \
      -out "$P12_PATH" \
      -inkey "$tmp/key.pem" \
      -in "$tmp/cert.pem" \
      -passout "pass:${P12_PASS}" \
      -name "$CERT_NAME" 2>/dev/null
  then
    export_ok=1
  fi

  if [[ "$export_ok" -ne 1 ]]; then
    echo "error: openssl pkcs12 export failed" >&2
    return 1
  fi

  chmod 600 "$P12_PATH"
  echo "Created stable signing cert: $P12_PATH"
}

emit_identity() {
  local hash
  hash="$(find_identity_hash)"
  if [[ -z "$hash" ]]; then
    return 1
  fi
  mkdir -p "$SIGN_DIR"
  echo "$hash" >"$HASH_PATH"
  chmod 600 "$HASH_PATH"
  # Prefer SHA hash — stable even when the display name varies.
  echo "$hash"
}

if identity_exists; then
  ensure_codesign_trust || true
  emit_identity
  exit 0
fi

NEED_GENERATE=1
if [[ -f "$P12_PATH" ]]; then
  echo "Importing existing ALWM signing certificate into login keychain…"
  if import_p12 "$P12_PATH" && identity_exists; then
    NEED_GENERATE=0
  else
    echo "Existing .p12 missing/incompatible — regenerating…"
    rm -f "$P12_PATH"
  fi
fi

if [[ "$NEED_GENERATE" -eq 1 ]]; then
  echo "Generating stable local code-signing certificate (once)…"
  generate_p12
  import_p12 "$P12_PATH" || true
fi

if ! identity_exists; then
  echo "error: failed to register '$CERT_NAME' in the keychain." >&2
  echo "Manual fix:" >&2
  echo "  1. Open Keychain Access → File → Import Items → $P12_PATH" >&2
  echo "  2. Password: $P12_PASS" >&2
  echo "  3. Double-click cert → Trust → Code Signing = Always Trust" >&2
  echo "  4. Re-run ./scripts/package.sh" >&2
  exit 1
fi

ensure_codesign_trust || true
emit_identity
