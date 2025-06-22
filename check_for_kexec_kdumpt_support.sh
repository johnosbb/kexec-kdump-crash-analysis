#!/bin/bash

REQUIRED_OPTIONS=(
  "CONFIG_KEXEC_CORE"
  "CONFIG_KEXEC_FILE"
  "CONFIG_CRASH_DUMP"
  "CONFIG_PROC_VMCORE"
  "CONFIG_DEBUG_INFO"
)

CONFIG_FILE="/boot/config-$(uname -r)"

# If /proc/config.gz is available, use it as a fallback
if [ ! -f "$CONFIG_FILE" ] && [ -f /proc/config.gz ]; then
  echo "Extracting kernel config from /proc/config.gz..."
  zcat /proc/config.gz > /tmp/kernel_config_check
  CONFIG_FILE="/tmp/kernel_config_check"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Could not find a kernel config file."
  exit 1
fi

echo "Checking kernel config in: $CONFIG_FILE"
echo "-------------------------------------------"

missing=0

for opt in "${REQUIRED_OPTIONS[@]}"; do
  if grep -q "^$opt=y" "$CONFIG_FILE"; then
    echo "$opt is enabled"
  else
    echo "$opt is NOT enabled"
    ((missing++))
  fi
done

echo "-------------------------------------------"
if [ "$missing" -eq 0 ]; then
  echo "All required Kexec/Kdump configs are enabled!"
else
  echo "$missing required option(s) are missing."
fi

# Cleanup temporary file if created
[ -f /tmp/kernel_config_check ] && rm /tmp/kernel_config_check
