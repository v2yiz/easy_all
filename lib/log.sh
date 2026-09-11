#!/usr/bin/env bash

# Shared logging primitives for easy_all runtime modules.

if [[ "${EASY_ALL_LOG_LOADED:-0}" != "1" ]]; then
    EASY_ALL_LOG_LOADED=1
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[1;36m'
    RESET='\033[0m'

    info() { printf '%b%s%b\n' "${CYAN}" "$*" "${RESET}"; }
    success() { printf '%b%s%b\n' "${GREEN}" "$*" "${RESET}"; }
    warn() { printf '%b%s%b\n' "${YELLOW}" "$*" "${RESET}"; }
    fail() { printf '%b%s%b\n' "${RED}" "$*" "${RESET}" >&2; return 1; }
    die() { fail "$*"; exit 1; }
fi
