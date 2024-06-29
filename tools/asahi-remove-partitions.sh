#!/usr/bin/env bash
#
# inspired to undo that which wsa done by https://fedora-asahi-remix.org
#         curl https://fedora-asahi-remix.org/install | sh
#

# Exit script if you tru to use an uninitialized variable.
set -o nounset

# Exit script if a statement returns a non-true return value.
set -o errexit

# Use the error status of the first failure, rather than that of the last item in a pipeline.
set -o pipefail

#
# https://ss64.com/mac/bless.html
#
# systemsetup -getstartupdisk
#
# https://support.apple.com/guide/security/boot-process-secac71d5623/web
#
# ideally, each partition would have a label indicated which OS installed it, and why.
# alas, GPT does not support such user-defined labels, nor does APFS.
# a manifest per install would be nice ... seems like m1n1 or uboot should be given that
# knowledge.
#
# Otherwise, it will be possible to create a unique APFS subvolume whose entire purpose
# is to use its APFS volume name as a label which is a concatenation of all partitions
# involved in the particular installation as a simple manifest
# until then, use a heurestic of one APFS partition followed by three naked GPT partitions
# and remove all 4 of those
#

function rough_draft() {
	.
# df / |grep '^/dev' | sed -e 's| .*||' -e 's|\/dev\/||'
# diskutil ap list -plist | plutil -convert json -o - -  | jq '.Containers | map(select(.PhysicalStores[].DeviceIdentifier | test("^disk0")))|map(select(.Volumes[].DeviceIdentifier == "disk4s1s1"))'
# eliminate containers which have a volume named "Update" or have device prefix matching the "/" mount point
# jq '. | map(select(.Volumes | all(.[]; .Name != "iSCPreboot"))) | map(select(.Volumes | all(.[]; .DeviceIdentifier != "disk4s1"))) | map(select(.Volumes | all(.[]; .Name != "Update")))| .[].PhysicalStores[].DeviceIdentifier'

}

function abort_with_error() {
	local -r error_message="${1}"
	printf 'asahi-remove-partitions failed with status: %s\n' "${error_message}" > /dev/stderr
	exit 1
}

#
# heuristics assumpts designed to play safe when we do not have an explicit manifest
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

function verify_prerequisites() {
	command -v brew
	command -v jq
	command -v diskutil
	command -v bless
	command -v df
	command -v reboot
}

function install_prerequisites() {
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	eval "$(/opt/homebrew/bin/brew shellenv)"
	brew install jq
}

function find_physical_internal_objects_as_json() {
	diskutil list -plist physical internal | plutil -convert json -o - -
}

function get_partition_info() {
	local -r targetPartition="${1}"
	diskutil info -plist "${targetPartition}" | plutil -convert json -o - -
}

function get_partition_container_reference() {
	local -r targetPartition="${1}"
	get_partition_info "${targetPartition}" | jq -r '.APFSContainerReference'
}

function json_filter_whole_disks() {
	jq -r '.WholeDisks[] | if type=="array" then sort else . end'
}

function json_get_all_partitions_for_disk() {
	local -r desiredDeviceIdentifier="${1}"
	jq -r --arg devID "${desiredDeviceIdentifier}" '.AllDisksAndPartitions | map(select(.DeviceIdentifier == $devID)) | if type=="array" then sort else . end'
}

function json_filter_select_non_apfs_partitions() {
	jq -r '.[].Partitions | map(select(.Content | test("^Apple_APFS")| not)).[] | .DeviceIdentifier'
}

function json_filter_select_apfs_partitions() {
	jq -r '.[].Partitions | map(select(.Content | test("^Apple_APFS"))).[] | .DeviceIdentifier'
}

function json_get_non_apfs_partitions_for_disk() {
	local -r desiredDeviceIdentifier="${1}"
	json_get_all_partitions_for_disk "${desiredDeviceIdentifier}" | json_filter_select_non_apfs_partitions
}

function json_get_apfs_partitions_for_disk() {
	local -r desiredDeviceIdentifier="${1}"
	json_get_all_partitions_for_disk "${desiredDeviceIdentifier}" | json_filter_select_apfs_partitions
}

function find_physical_internal_whole_disks() {
	find_physical_internal_objects_as_json | json_filter_whole_disks
}

function verify_physical_internal_whole_disk() {
	# returns DeviceIdentifier of internal drive if one drive in system
	IFS=$'\n' read -r -d '' -a physical_internal_whole_disks <<< "$(find_physical_internal_whole_disks)"
	printf '%s\n' "${physical_internal_whole_disks[@]}" 1>&2
	printf '%s' "${physical_internal_whole_disks[0]}"
	local -r count_internal_whole_disks="${#physical_internal_whole_disks[@]}"
	[[ ${count_internal_whole_disks} = $(expected_physical_disk_count) ]] || abort_with_error 'incorrect number of whole disks'
}

function find_non_apfs_gpt_partitions() {
	local -r desiredDeviceIdentifier="${1}"
	find_physical_internal_objects_as_json | json_get_non_apfs_partitions_for_disk "${desiredDeviceIdentifier}"
}

function verify_non_apfs_gpt_partitions() {
	local -r physical_disk="${1}"
	IFS=$'\n' read -r -d '' -a non_apfs_partitions <<< "$(find_non_apfs_gpt_partitions "${physical_disk}" )"
	printf '%s \n' "${non_apfs_partitions[@]}" 1>&2
	local -r count_non_apfs_partitions="${#non_apfs_partitions[@]}"
	[[ ${count_non_apfs_partitions} = $(expected_non_apfs_partition_count) ]] || abort_with_error 'incorrect number of non-APFS partitions'
	printf 'Verified [%d] non-apfs partitions\n' "${count_non_apfs_partitions}"
}

function find_apfs_gpt_partitions() {
	local -r desiredDeviceIdentifier="${1}"
	find_physical_internal_objects_as_json | json_get_apfs_partitions_for_disk "${desiredDeviceIdentifier}"
}

function verify_asahi_apfs_partition() {
	local -r asahiPartition="${1}"
	get_partition_container_reference "${asahiPartition}"
	# false	
}

function verify_apfs_gpt_partition() {
	local -r physical_disk="${1}"
	IFS=$'\n' read -r -d '' -a apfs_partitions <<< "$(find_apfs_gpt_partitions "${physical_disk}" )"
	printf '%s \n' "${apfs_partitions[@]}" 1>&2
	local -r count_apfs_partitions="${#apfs_partitions[@]}"
	[[ ${count_apfs_partitions} = $(expected_apfs_partition_count) ]] || abort_with_error 'incorrect number of APFS partitions'
	printf 'Verified [%d] apfs partitions\n' "${count_apfs_partitions}"
	asahi_apfs_partition="${apfs_partitions[2]}"
	verify_asahi_apfs_partition "${asahi_apfs_partition}" || abort_with_error 'unable to verify contents of asahi partition'
	printf 'Verified [%s] asahi apfs partition\n' "${asahi_apfs_partition}"
}

function verify_asahi_partition_assumptions() {
	local physical_disk
	physical_disk="$(verify_physical_internal_whole_disk)"
	verify_non_apfs_gpt_partitions "${physical_disk}"
	verify_apfs_gpt_partition "${physical_disk}"
}

function remove_asahi_non_apfs_gpt_partitions() {
	local -r physical_disk="${1}"
	IFS=$'\n' read -r -d '' -a non_apfs_partitions <<< "$(find_non_apfs_gpt_partitions "${physical_disk}" )"
	printf '%s \n' "${non_apfs_partitions[@]}" 1>&2
	for partition in "${non_apfs_partitions[@]}"; do
		echo "removing: $partition with \"diskutil eraseVolume free free $partition\""
		diskutil eraseVolume free free $partition
	done
}

function remove_asahi_apfs_partition() {
	local -r target_partition="${1}"
	echo "removing: asahi apfs partition [${asahi_apfs_partition}] with \"diskutil apfs deleteContainer ${asahi_apfs_partition}\""
	diskutil apfs deleteContainer ${asahi_apfs_partition}
}

function resize_apfs_partition() {
	local -r target_partition="${1}"
	echo "resizing: partition [${target_partition}] with \"diskutil apfs resizeContainer ${target_partition} 0\""
	diskutil apfs resizeContainer ${target_partition} 0
}

function remove_asahi_apfs_gpt_partitions_and_resize_predecessor() {
	local -r physical_disk="${1}"
	IFS=$'\n' read -r -d '' -a apfs_partitions <<< "$(find_apfs_gpt_partitions "${physical_disk}" )"
	printf '%s \n' "${apfs_partitions[@]}" 1>&2
	remove_asahi_apfs_partition "${apfs_partitions[2]}"
	resize_apfs_partition "${apfs_partitions[1]}"
}

function remove_asahi_partitions() {
	local physical_disk
	physical_disk="$(verify_physical_internal_whole_disk)"
	remove_asahi_non_apfs_gpt_partitions "${physical_disk}"
	remove_asahi_apfs_gpt_partitions_and_resize_predecessor "${physical_disk}"
}

function start_with_macos() {
	printf 'You may see a password prompt.  Applying your administrative password will allow MacOS to be'
	printf 'the default Startup Disk on the next reboot\n'
	bless --mount / --setBoot || abort_with_error 'Failed to (re)set startup disk'
}

function asahi_remove_partitions() {
	verify_prerequisites 1>&2 || abort_with_error 'Failed to verify prerequisites'
	verify_asahi_partition_assumptions || abort_with_error 'Could not verify previous asahi installation'
	remove_asahi_partitions || abort_with_error 'Could not remove the asahi partitions'
	start_with_macos || abort_with_error 'Failed to set MacOS as the startup OS'
	reboot || abort_with_error 'Failed to reboot'
}

asahi_remove_partitions #2> /dev/null

