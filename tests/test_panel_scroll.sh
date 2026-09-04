#!/usr/bin/env bash
set -u

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
commons_link="$plugin_dir/Commons"
ui_link="$plugin_dir/Ui"
user_home=${HOME:?}
state_target="$user_home/.local/state/omarchy/deco-mesh"
state_tmp=$(mktemp -d)
test_log=$(mktemp)
created_state_target=false

cleanup() {
  [[ -L "$commons_link" ]] && unlink "$commons_link"
  [[ -L "$ui_link" ]] && unlink "$ui_link"
  rm -r "$state_tmp"
  rm -f "$test_log"
  if [[ "$created_state_target" == true ]]; then
    rmdir "$state_target" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -e "$commons_link" || -e "$ui_link" ]]; then
  echo "Refusing to replace existing Commons or Ui paths in $plugin_dir" >&2
  exit 1
fi

if [[ ! -d "$state_target" ]]; then
  mkdir -p "$state_target"
  created_state_target=true
fi

ln -s /usr/share/omarchy/shell/Commons "$commons_link"
ln -s /usr/share/omarchy/shell/Ui "$ui_link"

bwrap \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --bind "$state_tmp" "$state_target" \
  --bind "/run/user/$(id -u)" "/run/user/$(id -u)" \
  -- env QT_QUICK_BACKEND=software timeout 10s \
  quickshell --no-duplicate --path "$plugin_dir/tst_panel_scroll.qml" --no-color \
  >"$test_log" 2>&1
run_status=$?

cat "$test_log"

if rg -q 'DECO_PANEL_TEST_PASS' "$test_log"; then
  exit 0
fi
if rg -q 'DECO_PANEL_TEST_FAIL' "$test_log"; then
  exit 1
fi
exit "$run_status"
