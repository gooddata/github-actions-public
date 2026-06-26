#!/usr/bin/env bash
# Native port of `cish fossa-scanning` scan loop. Reproduces the Jenkins
# docker-run invocation of fossa_scanning_tool inside the gdc-fossa-cli image.
#
# Auth uses org GitHub Actions secrets (no Vault): NPM_AUTH_TOKEN for npm, and a
# GitHub PAT (GITHUB_PULL_TOKEN) wired through a git insteadOf rewrite so the
# in-container dependency resolution can fetch private gooddata repos over HTTPS
# (replaces the Jenkins SSH-agent approach).
set -euo pipefail

: "${FOSSA_API_KEY:?FOSSA_API_KEY is required}"
: "${REPO_NAME:?REPO_NAME is required}"
NPM_AUTH_TOKEN="${NPM_AUTH_TOKEN:-}"
GITHUB_PULL_TOKEN="${GITHUB_PULL_TOKEN:-}"
SCAN_IMAGE_DEFAULT="${SCAN_IMAGE_DEFAULT:?SCAN_IMAGE_DEFAULT is required}"
FOSSA_BRANCH="${FOSSA_BRANCH:-}"

src_dir="${GITHUB_WORKSPACE:-$PWD}"
work_dir="${RUNNER_TEMP:-$PWD}/fossa-pr-scan"
mkdir -p "${PWD}/build-output" "${work_dir}"

# --- npm auth (mounted into the container as ~/.npmrc) ---
# Jenkins used the public registry with an auth token; npm interpolates the
# NPM_AUTH_TOKEN env var (also passed into the container) at runtime.
npmrc="${work_dir}/npmrc"
if [ -n "${NPM_AUTH_TOKEN}" ]; then
  printf '//registry.npmjs.org/:_authToken=${NPM_AUTH_TOKEN}\n' > "${npmrc}"
else
  : > "${npmrc}"
fi

# --- git auth for private gooddata deps (mounted into the container) ---
# Rewrite ssh/https gooddata URLs to token-authenticated HTTPS so go/npm/maven
# can resolve private dependencies in-container. The token is embedded in a
# throwaway gitconfig on the ephemeral runner.
gitconfig="${work_dir}/gitconfig"
: > "${gitconfig}"
if [ -n "${GITHUB_PULL_TOKEN}" ]; then
  cat > "${gitconfig}" <<EOF
[url "https://oauth2:${GITHUB_PULL_TOKEN}@github.com/gooddata/"]
	insteadOf = ssh://git@github.com/gooddata/
	insteadOf = git@github.com:gooddata/
	insteadOf = https://github.com/gooddata/
EOF
fi

# --- m2 settings (optional; only mounted if present) ---
m2_settings="${HOME}/.m2/settings.xml"

docker_pull() { docker pull "$1" >/dev/null; }

run_scan() {
  local scan_img="$1" gdc_conf="$2"
  local java_version="" conf_arg=()
  local mount_args=()

  if [ -n "${gdc_conf}" ] && [ -f "${gdc_conf}" ]; then
    local img_override
    img_override="$(yq -r '.scan_image | select(. != null)' "${gdc_conf}")"
    [ -n "${img_override}" ] && scan_img="${img_override}"
    java_version="$(yq -r '.java_version | select(. != null)' "${gdc_conf}")"
    conf_arg=(--gdc-conf "$(basename "${gdc_conf}")")
  fi

  docker_pull "${scan_img}"

  mount_args=(
    -v "${npmrc}:/home/fossa/.npmrc"
    -v "${gitconfig}:/home/fossa/.gitconfig"
    -v "${src_dir}:/home/fossa/sources/${REPO_NAME}"
    -v "${PWD}/build-output:/home/fossa/build-output"
  )
  if [ -f "${m2_settings}" ]; then
    mount_args+=(-v "${m2_settings}:/home/fossa/.m2/settings.xml")
  fi

  docker run --rm \
    "${mount_args[@]}" \
    -e USER_UID="$(id -u)" \
    -e FOSSA_API_KEY -e NPM_AUTH_TOKEN \
    -e JAVA_VERSION="${java_version}" \
    "${scan_img}" \
    fossa_scanning_tool -r "${REPO_NAME}" -o "not_found" -v -c analyze test \
      ${FOSSA_BRANCH:+-b "${FOSSA_BRANCH}"} \
      "${conf_arg[@]}"
}

# --- find gdc_fossa*.yaml configs; loop, or single scan if none ---
mapfile -t confs < <(find "${src_dir}" -type f -name "gdc_fossa*.yaml" | sort)
if [ "${#confs[@]}" -eq 0 ]; then
  run_scan "${SCAN_IMAGE_DEFAULT}" ""
else
  for conf in "${confs[@]}"; do
    run_scan "${SCAN_IMAGE_DEFAULT}" "${conf}"
  done
fi

# fossa_scanning_tool writes build-output/analyze_failed.txt on analyze failure
if [ -f "./build-output/analyze_failed.txt" ]; then
  echo "ERROR: FOSSA analyze failed for some module(s); see logs above."
  exit 1
fi
echo "FOSSA scan completed."
