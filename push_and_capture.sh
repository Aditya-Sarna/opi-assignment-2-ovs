#!/usr/bin/env bash
# Push this repo to GitHub and trigger the real-evidence capture workflow.
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}"

REPO_NAME="${1:-opi-assignment-2-ovs}"

if ! command -v gh >/dev/null 2>&1; then
  echo "Installing gh to ~/.local/bin ..."
  arch="$(uname -m)"
  case "${arch}" in
    arm64) gh_arch=macOS_arm64 ;;
    x86_64) gh_arch=macOS_amd64 ;;
    *) echo "Unsupported arch: ${arch}"; exit 1 ;;
  esac
  ver=2.63.2
  curl -fsSL "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_${gh_arch}.zip" -o /tmp/gh.zip
  unzip -qo /tmp/gh.zip -d /tmp/gh
  cp "/tmp/gh/gh_${ver}_${gh_arch}/bin/gh" "${HOME}/.local/bin/gh"
  chmod +x "${HOME}/.local/bin/gh"
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Log in to GitHub (browser will open):"
  gh auth login -h github.com -p https -w
fi

USER="$(gh api user -q .login)"
REMOTE="https://github.com/${USER}/${REPO_NAME}.git"

if git remote get-url origin >/dev/null 2>&1; then
  git push -u origin main
else
  gh repo create "${REPO_NAME}" --public --source=. --remote=origin --push
fi

echo "Triggering Capture OVS Evidence workflow ..."
gh workflow run "Capture OVS Evidence"
sleep 5
RUN_ID="$(gh run list --workflow="Capture OVS Evidence" --limit 1 --json databaseId -q '.[0].databaseId')"
echo "Watching run ${RUN_ID} (up to 3 hours) ..."
gh run watch "${RUN_ID}" --exit-status
mkdir -p artifacts
gh run download "${RUN_ID}" -D artifacts
echo "Done. Artifacts in artifacts/ovs-evidence/"
