#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
release_init "$@"
verify_developer_id "$app"

# Preserve an existing release until every distribution check has succeeded.
# A private copy also keeps an in-progress build from changing the upload.
work_dir="$(mktemp -d "$dist_dir/.notarize-${version}.XXXXXX")"
chmod 700 "$work_dir"
trap 'result=$?; if [ "$result" -ne 0 ]; then echo "Notarization stopped. Submission and diagnostics: $work_dir" >&2; fi' EXIT
ditto "$app" "$work_dir/LiteZip.app"
verify_developer_id "$work_dir/LiteZip.app"
ditto -c -k --sequesterRsrc --keepParent "$work_dir/LiteZip.app" "$work_dir/submission.zip"
(cd "$work_dir" && shasum -a 256 submission.zip) > "$work_dir/submission.sha256"

echo "Submitting LiteZip $version to Apple. Diagnostics: $work_dir"
xcrun notarytool submit "$work_dir/submission.zip" --keychain-profile "$notary_profile" \
  --no-wait --output-format json > "$work_dir/submission.json"
submission_id="$(plutil -extract id raw -o - "$work_dir/submission.json")"
echo "Waiting for Apple: $submission_id"
wait_result=0
xcrun notarytool wait "$submission_id" --keychain-profile "$notary_profile" \
  --output-format json > "$work_dir/result.json" || wait_result=$?
status="$(plutil -extract status raw -o - "$work_dir/result.json" 2>/dev/null || true)"
xcrun notarytool log "$submission_id" "$work_dir/apple-log.json" \
  --keychain-profile "$notary_profile" > "$work_dir/log-retrieval.txt" 2>&1 || true
if [ "$wait_result" -ne 0 ] || [ "$status" != Accepted ]; then
  echo "Apple notarization was not accepted (status: ${status:-unknown}). No release was replaced." >&2
  exit 1
fi

xcrun stapler staple "$work_dir/LiteZip.app"
xcrun stapler validate "$work_dir/LiteZip.app"
verify_developer_id "$work_dir/LiteZip.app"
spctl --assess --type execute --verbose=2 "$work_dir/LiteZip.app"
ditto -c -k --sequesterRsrc --keepParent "$work_dir/LiteZip.app" "$work_dir/$archive_name"
(cd "$work_dir" && shasum -a 256 "$archive_name") > "$work_dir/SHA256SUMS"
mv -f "$work_dir/$archive_name" "$dist_dir/$archive_name"
mv -f "$work_dir/SHA256SUMS" "$dist_dir/SHA256SUMS"
echo "Signed, notarized and stapled: $dist_dir/$archive_name"
