# Changelog

Historial de versiones del HomeLab Installer (HLI). Cada versión se construyó
resolviendo un problema real de administrar el servidor.

## [1.0.0] - 2026-06-15

Primera versión estable y pública. Validada en hardware real (Lenovo ThinkPad
T400, Ubuntu 26.04 LTS).

- Textos de la interfaz y documentación en español latinoamericano neutro.
- `CHANGELOG.md` y README completos.
- Correcciones encontradas probando en hardware real:
  - Jellyfin se instala por el repo APT oficial (el script con prompt colgaba
    cuando corría en segundo plano).
  - Detección de servicios con `systemctl cat` (el método anterior daba falso
    `not-installed` por `grep -q` + `pipefail`).
  - `wol.service` con `RemainAfterExit=yes` (queda `active`, no `inactive`).
  - Cancelar en un submenú ya no cierra el instalador; la terminal se restaura
    al salir.

## [0.11] - Disco de datos permanente

- `datadisk.sh`: monta un disco de datos de forma persistente (`/etc/fstab` por
  UUID + `nofail`), con opción de formatear (doble confirmación) y punto de
  montaje inteligente (`/srv/mediaN` libre para un segundo disco).

## [0.10] - Migración asistida

- `migrate.sh`: detecta el disco viejo conectado, resuelve la colisión de VG
  LVM (renombra por UUID), lo monta en solo lectura y restaura la configuración.
- `media-transfer.sh`: copia carpetas de media seleccionadas desde el disco
  viejo.
- Importación de `authorized_keys` al migrar/restaurar/respaldar (no hay que
  volver a correr `ssh-copy-id`).
- Flag `HLI-TIPO: tool`: las herramientas no aparecen en la instalación.
- Menú "Respaldos y migración" que agrupa crear/restaurar/disco viejo.

## [0.9] - Storage inteligente

- `storage.sh` detecta espacio libre en el LVM y ofrece extender la raíz a todo
  el disco (`lvextend -l +100%FREE -r`).

## [0.8] - Experiencia / Producto

- Dashboard con detección de hardware (modelo, CPU, RAM, disco, distro).
- Barra de progreso por módulo en la instalación completa.
- `update.sh`: modo actualización (`apt full-upgrade` + limpieza).
- `apt` no-interactivo y `sudo` con keep-alive.

## [0.7] - Backup y restore

- `backup.sh` / `restore.sh`: respaldo de configuración (sin media) en `.tar.gz`
  con manifiesto `config.yml`.

## [0.6] - Health Check

- `healthcheck.sh`: informe de discos (SMART), temperatura, RAM, espacio,
  servicios, red y uptime.

## [0.5] - Power management

- `power.sh`: desactivar suspensión, ignorar cierre de tapa.
- Perfil de servidor (`24/7` / `Escritorio` / `Notebook`).

## [0.4] - Plugin System

- Auto-descubrimiento de módulos por metadata (`HLI-MODULE`, `HLI-DESC`,
  `HLI-ORDER`, `HLI-DEFAULT`, `HLI-TUI`). El menú se construye solo.
- `run_module` no rompe la TUI (módulos interactivos heredan la terminal).

## [0.3] - Saneamiento

- `qbittorrent-nox` con `--confirm-legal-notice`.
- Grupo `media` correcto en el servicio de qBittorrent.

## [0.2] - Base

- Instalador TUI inicial: base, storage, WOL, Samba, Jellyfin, qBittorrent,
  AdGuard Home, estado, restore básico.
