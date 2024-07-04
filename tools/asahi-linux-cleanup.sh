#!/usr/bin/env bash
# shellcheck shell=bash
#
# clean up an installation of Asahi Linux by:
# 1. removing all partitions created by the Asahi Linux installer, and
# 2. resizing the preceding APFS GPT partition to re-occupy the free space resulting from [1], and
# 3. removing `iSCPPreboot` information related to the Asahi Linux installer, and
# 4. blessing the currently running macOS as the default boot OS
#
# if it seems like a lot of code to accomplish something seeming so simple,
# the primary factor driving the code size is that it is intensely paranoid
# about preventing the accidental removal of something valuable to the machine's
# users which was not created during the Asahi Linux install process.
#
# currently, cleanup will fail prior to commencing if:
# 1) there is more than one ESP (EFI System Partition)
# 2) there are more than 4 contiguous partitions not installed for macOS
#
# bibliographic information:
# 1) https://ss64.com/mac/bless.html
# 2) https://support.apple.com/guide/security/boot-process-secac71d5623/web
# 3)

# bash configuration:
# 1) Exit script if you tru to use an uninitialized variable.
set -o nounset

# 2) Exit script if a statement returns a non-true return value.
set -o errexit

# 3) Use the error status of the first failure, rather than that of the last item in a pipeline.
set -o pipefail

## arguments
declare -rx OUTER_SCRIPT="${OUTER_SCRIPT:-${0}}"

# @@
# ideally, each partition would have a label indicated which OS installed it, and why.
# alas, GPT does not support such user-defined labels, nor does APFS.
# a manifest per install would be nice ... seems like m1n1 or uboot should be given that
# knowledge.
#
# Otherwise, it will be possible to create a unique APFS subvolume whose entire purpose
# is to use its APFS volume name as a label which is a concatenation of all partitions
# involved in the particular installation as a simple manifest
# until then, use a heuristic of one APFS partition followed by three naked GPT partitions
# and remove all 4 of those
#

function abort_with_error() {
  local -r error_message="${1}"
  local -r error_code="${2}"
  printf '%s failed with status: %s errno=%d\n' "${OUTER_SCRIPT}" "${error_message}" "${error_code}" >/dev/stderr
  exit 1
}

#
# heuristics assumptions designed to play safe when we do not have an explicit manifest
# of disk objects to be deleted
#

function expected_physical_disk_count() {
  printf '1'
}

function expected_apfs_partition_count() {
  printf '4'
}

function expected_non_apfs_partition_count() {
  printf '3'
}

function verify_cleaner_prerequisites() {
  {
    command -v brew
    command -v jq
    command -v diskutil
    command -v bless
    command -v df
    command -v reboot
  } || abort_with_error 'Failed to verify cleaner prerequisites' $?
}

function install_prerequisites() {
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  brew install jq
}

function pl2json() {
  plutil -convert json -o - -
}

function find_physical_internal_objects_as_json() {
  diskutil list -plist physical internal | pl2json
}

function get_partition_info() {
  local -r targetPartition="${1}"
  diskutil info -plist "${targetPartition}" | pl2json
}

function get_partition_container_reference() {
  local -r targetPartition="${1}"
  get_partition_info "${targetPartition}" | jq -r '.APFSContainerReference'
}

function filter_whole_disks() {
  jq -r '.WholeDisks[]' | sort
}

function jq_get_all_partitions_for_disk() {
  cat <<'JQSCRIPT'
  .AllDisksAndPartitions
  | map(select(.DeviceIdentifier == $devID))
JQSCRIPT
}

function get_all_partitions_for_disk() {
  local -r desiredDeviceIdentifier="${1}"
  jq -r --arg devID "${desiredDeviceIdentifier}" "$(jq_get_all_partitions_for_disk)" | sort
}

function jq_filter_select_non_apfs_partitions() {
  cat <<'JQSCRIPT'
  .[].Partitions
  | map(select(.Content
  | test("^Apple_APFS")| not)).[]
  | .DeviceIdentifier'
JQSCRIPT
}

function filter_select_non_apfs_partitions() {
  jq -r "$(jq_filter_select_non_apfs_partitions)"
}

function get_non_apfs_partitions_for_disk() {
  local -r desiredDeviceIdentifier="${1}"
  get_all_partitions_for_disk "${desiredDeviceIdentifier}" | filter_select_non_apfs_partitions
}

function jq_filter_select_apfs_partitions() {
  cat <<'JQSCRIPT'
  .[].Partitions
  | map(select(.Content
  | test("^Apple_APFS"))).[]
  | .DeviceIdentifier'
JQSCRIPT
}
function filter_select_apfs_partitions() {
  jq -r "$(jq_filter_select_apfs_partitions)"
}

function get_apfs_partitions_for_disk() {
  local -r desiredDeviceIdentifier="${1}"
  get_all_partitions_for_disk "${desiredDeviceIdentifier}" | filter_select_apfs_partitions
}

function find_physical_internal_whole_disks() {
  find_physical_internal_objects_as_json | filter_whole_disks
}

function verify_physical_internal_whole_disk() {
  local physical_internal_whole_disks
  # returns DeviceIdentifier of internal drive if one drive in system
  IFS=$'\n' read -r -d '' -a physical_internal_whole_disks <<<"$(find_physical_internal_whole_disks)"
  printf '%s\n' "${physical_internal_whole_disks[@]}" 1>&2
  printf '%s' "${physical_internal_whole_disks[0]}"
  local -r count_internal_whole_disks="${#physical_internal_whole_disks[@]}"
  [[ ${count_internal_whole_disks} == $(expected_physical_disk_count) ]] ||
    abort_with_error 'incorrect number of whole disks' "$(false)"
}

function find_non_apfs_gpt_partitions() {
  local -r desiredDeviceIdentifier="${1}"
  find_physical_internal_objects_as_json | get_non_apfs_partitions_for_disk "${desiredDeviceIdentifier}"
}

function verify_non_apfs_gpt_partitions() {
  local -r physical_disk="${1}"
  IFS=$'\n' read -r -d '' -a non_apfs_partitions <<<"$(find_non_apfs_gpt_partitions "${physical_disk}")"
  printf '%s \n' "${non_apfs_partitions[@]}" 1>&2
  local -r count_non_apfs_partitions="${#non_apfs_partitions[@]}"
  [[ ${count_non_apfs_partitions} == $(expected_non_apfs_partition_count) ]] ||
    abort_with_error 'incorrect number of non-APFS partitions' "$(false)"
  printf 'Verified [%d] non-apfs partitions\n' "${count_non_apfs_partitions}"
}

function find_apfs_gpt_partitions() {
  local -r desiredDeviceIdentifier="${1}"
  find_physical_internal_objects_as_json | get_apfs_partitions_for_disk "${desiredDeviceIdentifier}"
}

function verify_asahi_apfs_partition() {
  local -r asahiPartition="${1}"
  get_partition_container_reference "${asahiPartition}"
  # false
}

function verify_apfs_gpt_partition() {
  local -r physical_disk="${1}"
  IFS=$'\n' read -r -d '' -a apfs_partitions <<<"$(find_apfs_gpt_partitions "${physical_disk}")"
  printf '%s \n' "${apfs_partitions[@]}" 1>&2
  local -r count_apfs_partitions="${#apfs_partitions[@]}"
  [[ ${count_apfs_partitions} == $(expected_apfs_partition_count) ]] ||
    abort_with_error 'incorrect number of APFS partitions' "$(false)"
  printf 'Verified [%d] apfs partitions\n' "${count_apfs_partitions}"
  asahi_apfs_partition="${apfs_partitions[2]}"
  verify_asahi_apfs_partition "${asahi_apfs_partition}" ||
    abort_with_error 'unable to verify contents of asahi partition' $?
  printf 'Verified [%s] asahi apfs partition\n' "${asahi_apfs_partition}"
}

function verify_asahi_partition_assumptions() {
  {
    local physical_disk
    physical_disk="$(verify_physical_internal_whole_disk)"
    verify_non_apfs_gpt_partitions "${physical_disk}"
    verify_apfs_gpt_partition "${physical_disk}"
  } || abort_with_error 'Could not verify previous asahi installation' $?
}

function remove_asahi_non_apfs_gpt_partitions() {
  local -r physical_disk="${1}"
  IFS=$'\n' read -r -d '' -a non_apfs_partitions <<<"$(find_non_apfs_gpt_partitions "${physical_disk}")"
  printf '%s \n' "${non_apfs_partitions[@]}" 1>&2
  local partition
  for partition in "${non_apfs_partitions[@]}"; do
    echo "removing: ${partition} with 'diskutil eraseVolume free free ${partition}'"
    diskutil eraseVolume free free "${partition}"
  done
}

function remove_asahi_apfs_partition() {
  local -r target_partition="${1}"
  echo "removing: asahi apfs partition [${target_partition}] with [diskutil apfs deleteContainer ${asahi_apfs_partition}]"
  diskutil apfs deleteContainer "${target_partition}"
}

function resize_apfs_partition() {
  local -r target_partition="${1}"
  echo "resizing: partition [${target_partition}] with [diskutil apfs resizeContainer ${target_partition} 0]"
  diskutil apfs resizeContainer "${target_partition}" 0
}

function remove_asahi_apfs_gpt_partitions_and_resize_predecessor() {
  local -r physical_disk="${1}"
  IFS=$'\n' read -r -d '' -a apfs_partitions <<<"$(find_apfs_gpt_partitions "${physical_disk}")"
  printf '%s \n' "${apfs_partitions[@]}" 1>&2
  remove_asahi_apfs_partition "${apfs_partitions[2]}"
  resize_apfs_partition "${apfs_partitions[1]}"
}

function remove_asahi_partitions() {
  {
    local physical_disk
    physical_disk="$(verify_physical_internal_whole_disk)"
    remove_asahi_non_apfs_gpt_partitions "${physical_disk}"
    remove_asahi_apfs_gpt_partitions_and_resize_predecessor "${physical_disk}"
  } || abort_with_error 'Could not remove the asahi partitions' $?
}

function start_with_macos() {
  {
    printf 'You may see a password prompt.  Applying your administrative password will allow MacOS to be'
    printf 'the default Startup Disk on the next reboot\n'
    bless --mount / --setBoot
  } || abort_with_error 'Failed to set MacOS as the startup OS' $?
}

function reboot_after_cleanup() {
  reboot || abort_with_error 'Failed to reboot' $?
}

function warn_user() {
  printf 'You may be prompted by sudo to increase the privileges from your\n'
  printf 'user default to those needed in order to correctly clean out\n'
  printf 'the desired Asahi Linux installation.\n'
  printf 'if you do not intend to remove an Asahi Linux installation, please\n'
  printf 'Press Control-C, otherwise, press <Enter>'

  read -r
}

function asahi_linux_cleaner_privileged() {
  local -r target_partition="${1}"

  verify_cleaner_prerequisites "${target_partition}" 1>&2
  verify_asahi_partition_assumptions "${target_partition}"

  printf 'Verified assumptions needed and commencing cleanup\n'

  # set subsequent boots to macOS
  #   this must be the first step after verification
  #   in order to recover from an incomplete cleanup

  start_with_macos
  remove_asahi_partitions"${target_partition}"
  reboot_after_cleanup
}

function asahi_linux_cleaner() {
  declare -x target_partition="${1:-}"
  warn_user
  sudo bash -c "$(declare -f); OUTER_SCRIPT=${OUTER_SCRIPT} asahi_linux_cleaner_privileged ${target_partition}"
}

#
# entry point is here
#
asahi_linux_cleaner "${@}"
