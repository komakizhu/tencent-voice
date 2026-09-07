#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
application_path="/Applications/Rime Voice.app"
built_app="${project_root}/dist/Rime Voice.app"

case "${application_path}" in
  /Applications/Rime\ Voice.app) ;;
  *)
    print -u2 "refusing to install to unexpected path: ${application_path}"
    exit 65
    ;;
esac

TVMVP_OUTPUT_APP="${built_app}" TVMVP_PACING_PRESET=balanced "${script_dir}/build-app.sh"

case "${built_app}" in
  "${project_root}/dist/Rime Voice.app") ;;
  *)
    print -u2 "refusing to install unexpected build path: ${built_app}"
    exit 66
    ;;
esac

if [[ -e "${application_path}" && ! -d "${application_path}" ]]; then
  print -u2 "install target is not an app bundle: ${application_path}"
  exit 67
fi
if [[ ! -w "/Applications" && ! -w "${application_path}" ]]; then
  print -u2 "no write permission for ${application_path}; run this script from an administrator account"
  exit 68
fi

current_user="$(id -un)"
for pid in ${(f)"$(pgrep -x TencentVoiceMVP 2>/dev/null || true)"}; do
  process_user="$(ps -o user= -p "${pid}" 2>/dev/null | tr -d ' ')"
  process_command="$(ps -o command= -p "${pid}" 2>/dev/null)"
  if [[ "${process_user}" == "${current_user}" \
    && ("${process_command}" == */Rime\ Voice.app/Contents/MacOS/TencentVoiceMVP* \
      || "${process_command}" == */TencentVoiceMVP.app/Contents/MacOS/TencentVoiceMVP*) ]]; then
    kill "${pid}"
  fi
done

ditto --rsrc --acl "${built_app}" "${application_path}"

# Normal launches never request TCC permissions. This explicit script opens
# the system settings page instead; macOS requires the user to enable TCC.
if [[ "${TVMVP_OPEN_PERMISSION_SETTINGS:-1}" == "1" ]]; then
  "${script_dir}/request-permissions.sh" all
fi
open -g -a "${application_path}"
print "${application_path}"
