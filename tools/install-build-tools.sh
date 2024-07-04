#!/usr/bin/env bash
# shellcheck shell=bash
#

## bash configuration:

# 1) Exit script if you tru to use an uninitialized variable.
set -o nounset

# 2) Exit script if a statement returns a non-true return value.
set -o errexit

# 3) Use the error status of the first failure, rather than that of the last item in a pipeline.
set -o pipefail

### external environment
declare -rx GITHUB_ACTIONS="${GITHUB_ACTIONS:-}"

function install_homebrew() {
  # Set the non-interactive environment variable for Homebrew
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(brew shellenv)"
}

function install_llvm() {
  brew install llvm
}

function install_rust_for_apple_silicon() {
  brew install rustup-init
  rustup-init --no-modify-path -y
  rustup target add aarch64-apple-darwin
  rustup target add aarch64-unknown-none-softfloat

  . "$HOME/.cargo/env"
}

function install_7z() {
  brew install p7zip
}

function install_certifi() {
  brew install certifi
}

function install_gcc_arm64() {
  brew install gcc
  brew tap osx-cross/arm
  brew install arm-none-eabi-gcc
  if [[ "$(uname -p)" == "i386" ]]; then
    brew install aarch64-elf-gcc
  else
    brew install aarch-linux-gnu
  fi
}

function main() {
  if [ -z "$GITHUB_ACTIONS" ]; then
    install_homebrew
  fi
  install_llvm
  install_rust_for_apple_silicon
  install_7z
  install_certifi
  install_gcc_arm64
}

#
# entry point is here
#
main "${@:-}"
