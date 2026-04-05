#!/usr/bin/env bash
#
# Скачивание (опционально) и развёртывание образа Wive на Proxmox VE.
# Запуск: root на узле Proxmox.
#
# Переменные окружения (все необязательны):
#   VMID             — ID виртуальной машины (по умолчанию: первый свободный от 123)
#   STORAGE          — хранилище дисков (по умолчанию: local-lvm)
#   BRIDGE_WAN       — мост для net0 (по умолчанию: vmbr1)
#   BRIDGE_LAN       — мост для net1 (по умолчанию: vmbr2)
#   RAM              — МБ ОЗУ (по умолчанию: 1024)
#   CORES            — число vCPU (по умолчанию: 4)
#   WIVE_IMAGE_URL   — прямой URL на bootfs.img (имеет приоритет над архивом)
#   WIVE_ARCHIVE_URL — URL .tar.xz с SourceForge (по умолчанию: см. ниже)
#   SKIP_DOWNLOAD    — если 1, не скачивать; нужен локальный bootfs.img
#   FORCE_DOWNLOAD   — если 1, скачать заново даже при наличии bootfs.img
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_NAME="bootfs.img"
DISK_PATH="${SCRIPT_DIR}/${DISK_NAME}"

# Официальный архив Wive-NG x86_64 (внутри — bootfs.img и др.)
DEFAULT_WIVE_ARCHIVE_URL="https://sourceforge.net/projects/wive-ng/files/wive-x86-64/wive-x86_64-9.8.6-13.10.2025.tar.xz/download"

STORAGE="${STORAGE:-local-lvm}"
BRIDGE_WAN="${BRIDGE_WAN:-vmbr1}"
BRIDGE_LAN="${BRIDGE_LAN:-vmbr2}"
RAM="${RAM:-1024}"
CORES="${CORES:-4}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"
WIVE_ARCHIVE_URL="${WIVE_ARCHIVE_URL:-$DEFAULT_WIVE_ARCHIVE_URL}"

die() { echo "Ошибка: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root (sudo)."

command -v qm >/dev/null 2>&1 || die "Не найден qm — запускайте на узле Proxmox VE."
command -v pvesm >/dev/null 2>&1 || die "Не найден pvesm."
command -v tar >/dev/null 2>&1 || die "Не найден tar."

download_to() {
  local url="$1" out="$2"
  echo "Загрузка: ${url}"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "${out}.part" "${url}" && mv -f "${out}.part" "${out}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${out}.part" "${url}" && mv -f "${out}.part" "${out}"
  else
    die "Нужен curl или wget."
  fi
}

extract_bootfs_from_archive() {
  command -v xz >/dev/null 2>&1 || die "Нужен xz для распаковки .tar.xz (apt install xz-utils)."
  local arch="$1"
  local exdir="${SCRIPT_DIR}/.wive-extract.$$"
  rm -rf "${exdir}"
  mkdir -p "${exdir}"
  echo "Распаковка архива..."
  tar -xJf "${arch}" -C "${exdir}"
  local found
  found="$(find "${exdir}" -name "${DISK_NAME}" -type f 2>/dev/null | head -1)"
  [[ -n "${found}" ]] || die "В архиве не найден ${DISK_NAME}. Проверьте состав сборки на sourceforge.net/projects/wive-ng."
  cp -a "${found}" "${DISK_PATH}"
  rm -rf "${exdir}"
  echo "Получен ${DISK_PATH}"
}

# Получение bootfs.img
if [[ "${SKIP_DOWNLOAD}" == "1" ]]; then
  [[ -f "${DISK_PATH}" ]] || die "SKIP_DOWNLOAD=1: положите ${DISK_PATH} вручную."
  echo "Используется локальный ${DISK_PATH} (без скачивания)."
elif [[ -f "${DISK_PATH}" ]] && [[ "${FORCE_DOWNLOAD}" != "1" ]]; then
  echo "Используется существующий ${DISK_PATH} (FORCE_DOWNLOAD=1 для повторной загрузки)."
elif [[ -n "${WIVE_IMAGE_URL:-}" ]]; then
  download_to "${WIVE_IMAGE_URL}" "${DISK_PATH}"
else
  arch_path="${SCRIPT_DIR}/wive-x86_64-archive.tar.xz"
  download_to "${WIVE_ARCHIVE_URL}" "${arch_path}"
  extract_bootfs_from_archive "${arch_path}"
  if [[ "${KEEP_ARCHIVE:-0}" != "1" ]]; then
    rm -f "${arch_path}"
    echo "Архив удалён (KEEP_ARCHIVE=1 — сохранить рядом со скриптом)."
  fi
fi

[[ -f "${DISK_PATH}" ]] || die "Нет файла ${DISK_PATH}."

qemu-img info "${DISK_PATH}" >/dev/null 2>&1 || die "Файл ${DISK_PATH} не похож на образ диска."

# VMID (свободный: qm config для несуществующей ВМ завершается с ошибкой)
if [[ -z "${VMID:-}" ]]; then
  VMID=""
  for try in 123 124 125 126 127 128 129 130; do
    if ! qm config "${try}" >/dev/null 2>&1; then
      VMID="${try}"
      break
    fi
  done
  [[ -n "${VMID}" ]] || die "Укажите свободный VMID вручную: export VMID=..."
else
  qm config "${VMID}" >/dev/null 2>&1 && die "VMID ${VMID} уже занят. Задайте другой: export VMID=..."
fi

echo "Создание ВМ ${VMID} (Wive), ОЗУ ${RAM} МБ, ${CORES} CPU, диски: ${STORAGE}"

qm create "${VMID}" \
  --name Wive \
  --memory "${RAM}" \
  --cores "${CORES}" \
  --cpu host \
  --net0 "e1000,bridge=${BRIDGE_WAN}" \
  --net1 "e1000,bridge=${BRIDGE_LAN}" \
  --ostype l26 \
  --machine q35 \
  --bios seabios \
  --agent 1 \
  --description "Wive router (import). SATA disk, e1000 NICs. Deploy: deploy-wive-proxmox.sh"

echo "Импорт диска (может занять несколько минут)..."
qm importdisk "${VMID}" "${DISK_PATH}" "${STORAGE}" --format raw

qm set "${VMID}" \
  --sata0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1" \
  --boot "order=sata0"

if qm config "${VMID}" | grep -q '^unused0:'; then
  qm set "${VMID}" --delete unused0 2>/dev/null || true
fi

echo ""
echo "Готово. ВМ: ${VMID}"
echo "  Запуск: qm start ${VMID}"
echo "  Конфиг: qm config ${VMID}"
echo ""
echo "Сеть: net0=e1000 -> ${BRIDGE_WAN}, net1=e1000 -> ${BRIDGE_LAN}"
echo "Диск: sata0 (не virtio-scsi). При смене типа шины загрузка может сломаться."
