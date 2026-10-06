#!/usr/bin/env bash
# Keep local Keychain trust stable; never silently switch a previously selected signer.
burro_signing_identity() {
  local requested="$1" saved="$2" identities="$3" trusted="$4" selected
  if [[ -n "$requested" ]]; then printf '%s\n' "$requested"; return; fi
  if [[ -n "$saved" && "$saved" != '-' ]]; then
    if [[ "$identities" == *"$saved"* ]]; then printf '%s\n' "$saved"; return; fi
    echo "Burro's saved signing identity is unavailable. Unlock its Keychain or restore the certificate, then rebuild. No fallback was signed. Set BURRO_SIGNING_IDENTITY only to intentionally change identity." >&2
    return 1
  fi
  selected="$(printf '%s\n' "$identities" | sed -nE 's/.* ([[:xdigit:]]{40}) "Apple Development:.*$/\1/p' | head -1)"
  if [[ -z "$selected" && "$trusted" == yes ]]; then
    echo "A trusted Burro build exists, but no signing certificate is available. Refusing an automatic ad-hoc downgrade that would lose Keychain approval." >&2
    return 1
  fi
  printf '%s\n' "${selected:--}"
}

burro_check_signing_requirement() {
  local previous="$1" current="$2" trusted="$3" requested="$4"
  if [[ "$current" != 'designated => '* ]]; then
    echo "Cannot verify Burro's signing requirement." >&2; return 1
  fi
  if [[ "$trusted" == yes && "$previous" != "$current" ]]; then
    if [[ -z "$requested" ]]; then
      echo "Burro's signing requirement changed. The existing app was preserved. Select the previous identity, or set BURRO_SIGNING_IDENTITY to intentionally replace it." >&2
      return 1
    fi
    echo "The explicit signing change may require one new Keychain approval." >&2
  fi
}
