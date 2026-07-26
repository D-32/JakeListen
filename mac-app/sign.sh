#!/usr/bin/env bash
# Sign a binary or .app bundle with a STABLE, self-signed code-signing identity.
#
# Why: macOS TCC (microphone, system-audio recording) keys a granted permission
# to the code signature. Ad-hoc signatures (`codesign --sign -`) have no stable
# identity, so every rebuild produces a new code-hash and the grant is lost —
# you'd have to re-allow recording after each build. Signing with a persistent
# self-signed identity makes TCC match on the identity instead, so the grant
# survives rebuilds (and updates signed with the same identity).
#
# The identity lives in a dedicated keychain with a known password (a local,
# self-signed code-signing cert — not a secret), created once and reused. Using
# our own keychain lets us set the key's partition list non-interactively so
# codesign never prompts. Falls back to ad-hoc signing if anything is missing.
#
# Usage: macos-sign.sh <path-to-binary-or-.app>
set -uo pipefail

TARGET="${1:?usage: macos-sign.sh <path-to-binary-or-.app>}"
IDENTITY="JakeListen Code Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/jakelisten-signing.keychain-db"
KC_PASS="jakelisten"

DEEP=""
case "$TARGET" in
	*.app) DEEP="--deep" ;;
esac

identity_ready() {
	security find-certificate -c "$IDENTITY" "$SIGN_KEYCHAIN" >/dev/null 2>&1
}

# Make sure our keychain is unlocked and on the user search list (so codesign
# and find-identity can see it). Idempotent.
prepare_keychain() {
	security unlock-keychain -p "$KC_PASS" "$SIGN_KEYCHAIN" 2>/dev/null || return 1
	local list
	list=$(security list-keychains -d user | sed 's/[" ]//g')
	case "$list" in
		*"$SIGN_KEYCHAIN"*) : ;;
		*) security list-keychains -d user -s "$SIGN_KEYCHAIN" $list >/dev/null 2>&1 ;;
	esac
}

create_identity() {
	command -v openssl >/dev/null 2>&1 || return 1
	if [ ! -f "$SIGN_KEYCHAIN" ]; then
		security create-keychain -p "$KC_PASS" "$SIGN_KEYCHAIN" || return 1
		security set-keychain-settings "$SIGN_KEYCHAIN"   # no auto-lock timeout
	fi
	prepare_keychain || return 1
	local tmp; tmp="$(mktemp -d)" || return 1
	cat >"$tmp/openssl.cnf" <<-EOF
		[req]
		distinguished_name = dn
		x509_extensions = v3
		prompt = no
		[dn]
		CN = $IDENTITY
		[v3]
		basicConstraints = critical,CA:false
		keyUsage = critical,digitalSignature
		extendedKeyUsage = critical,codeSigning
	EOF
	local rc=0
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/openssl.cnf" >/dev/null 2>&1 || rc=1
	# -legacy: macOS's importer can't verify OpenSSL 3's default PKCS#12 MAC.
	[ $rc -eq 0 ] && openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
		-out "$tmp/id.p12" -passout pass:"$KC_PASS" >/dev/null 2>&1 || rc=$rc
	[ $rc -eq 0 ] && security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P "$KC_PASS" \
		-T /usr/bin/codesign >/dev/null 2>&1 || rc=$rc
	# Authorise codesign to use the key without a GUI prompt (needs the kc password).
	[ $rc -eq 0 ] && security set-key-partition-list -S apple-tool:,apple:,codesign: \
		-s -k "$KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || rc=$rc
	rm -rf "$tmp"
	return $rc
}

if { identity_ready || create_identity; } && prepare_keychain; then
	if codesign --force $DEEP --sign "$IDENTITY" --keychain "$SIGN_KEYCHAIN" "$TARGET" 2>/dev/null; then
		echo "✓ Signed with stable identity \"$IDENTITY\" — recording permissions persist across rebuilds." >&2
		echo "  (A fresh install still needs a one-time Allow for mic/system-audio; rebuilds won't ask again.)" >&2
		exit 0
	fi
fi

echo "! Stable signing unavailable — using ad-hoc signature." >&2
echo "  You may need to re-grant microphone / system-audio permission after each rebuild." >&2
codesign --force $DEEP --sign - "$TARGET" 2>/dev/null || true
