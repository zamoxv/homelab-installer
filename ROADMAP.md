# Roadmap — HomeLab Installer (HLI)

## Misión

Que migrar el servidor completo a un equipo nuevo (Lenovo M70q Gen 3, Dell
OptiPlex, etc.) tome **menos de 30 minutos**. Objetivo final: **15 minutos**.

El instalador no es un script de conveniencia: es el seguro de migración del
homelab. Cada problema real que aparece administrando el servidor (Jellyfin tras
un corte de luz, permisos de Samba, WOL, discos nuevos, suspensión) se convierte
en un módulo o una mejora del HLI.

## Principios

- **Plugin System / auto-discovery**: el menú lee la carpeta `modules/`. No se
  hardcodea ningún módulo. Agregar `modules/x.sh` lo hace aparecer en el menú.
- **Idempotencia**: re-ejecutar cualquier módulo no rompe el sistema.
- **Bash estricto**: `set -euo pipefail` en todo.
- **Logs por módulo** en `/var/log/homelab-installer/`.
- **Estado persistente** en `/var/lib/homelab-installer/state`.

## Estado actual — v0.2 (hecho)

Punto de partida del repositorio. Ya construido en la base actual:

- Base Ubuntu y utilidades
- Dashboard de servicios
- Estructura `/srv` (storage)
- Wake-on-LAN
- Samba + carpetas compartidas
- Jellyfin
- qBittorrent-nox como servicio
- AdGuard Home
- Estado de servicios
- Restore básico
- Logs

JASJIC queda fuera del proyecto (tiene sus propios scripts).

---

## Fases

Cada fase es **un commit + un push** a GitHub.

### v0.3 — Saneamiento (correctness)

Fixes de bugs reales detectados en la base actual, independientes de la
arquitectura:

- [x] `qbittorrent-nox` sin `--confirm-legal-notice`: el servicio no arranca en
  el primer boot.
- [x] `qbittorrent.service` usa `Group=$SERVER_USER` en vez de `$MEDIA_GROUP`:
  inconsistencia de permisos con Jellyfin/Samba.
- [x] `mark_done` se invoca duplicado (en cada módulo y en `run_module`).

### v0.4 — Núcleo: Plugin System (la columna vertebral)

El refactor que sostiene todo lo demás. Se hace antes que cualquier módulo nuevo
porque todos dependen de él.

- [x] Contrato de módulo: cabecera de metadata que cada módulo expone con 5
  claves — `HLI-MODULE`, `HLI-DESC`, `HLI-ORDER`, `HLI-DEFAULT` (entra en
  instalación completa / pre-marcado) y `HLI-TUI` (es interactivo).
- [x] Auto-discovery: el menú y la "instalación completa" se construyen leyendo
  `modules/` (`list_modules` + `module_meta`), no listas escritas a mano.
- [x] Eliminar listas hardcodeadas (`ui/menu.sh`, `FULL_INSTALL_MODULES`).
- [x] Reescribir `run_module` para no romper la TUI: los módulos `TUI: yes`
  heredan la terminal real (dialog/prompts/smbpasswd funcionan); los batch se
  siguen volcando al log. Mata el bug del pipe a `tee` en `samba` y `restore`.

### v0.5 — Power Management + Perfiles de servidor

- [x] `modules/power.sh`: enmascarar `sleep/suspend/hibernate/hybrid-sleep`
  targets, ignorar cierre de tapa vía drop-in en `logind.conf.d/`, detectar swap
  y ofrecer mantener hibernación. Auto-descubierto por el plugin system (order
  25), sin tocar menú ni config.
- [x] Perfil de servidor (`24/7` / `Escritorio` / `Notebook`) como acción de
  menú. `24/7` reutiliza `power` + `wol` y aplica inline: límite de `journald`,
  `fstrim.timer` si detecta SSD, `smartd` si detecta HDD (vía `lsblk ROTA`).

### v0.6 — Health Check

- [x] `modules/healthcheck.sh`: informe best-effort de SMART de discos,
  temperatura, RAM, espacio libre, estado de servicios, IP, DNS, puertos
  abiertos y uptime. Drop-in (order 95) + entrada propia en el menú principal.

### v0.7 — Backup y Restore de migración

- [x] `modules/backup.sh`: genera `backup-YYYY-MM-DD.tar.gz` con config/estado
  de Jellyfin, qBittorrent, Samba y HLI + manifiesto `config.yml`. Sin media.
- [x] `restore.sh` con dos orígenes: backup HLI (.tar.gz) o disco viejo montado;
  restaura cada componente a su lugar y arregla permisos/servicios.

### v0.8 — Experiencia / Producto

- [x] Dashboard enriquecido: equipo (modelo), CPU, RAM, disco (tipo SSD/HDD),
  distro, IP, estado de servicios y barra ASCII de espacio.
- [x] Barra de progreso por módulo en "instalación completa" (`dialog --gauge`,
  módulo en segundo plano, salida al log, aviso si falla).
- [x] Detección automática: interfaz de red (`detect_iface`) y hardware
  (`hw_model`/`hw_cpu`/`hw_ram`/`hw_disk`).
- [x] Modo actualización: `modules/update.sh` (`apt update`/`full-upgrade`,
  `autoremove`, `autoclean`).
- [x] apt no-interactivo (confdef/confold + needrestart auto) y `sudo` con
  keep-alive: instalaciones en segundo plano sin prompts que cuelguen.

### v0.9 — Storage inteligente: auto-expandir LVM

**Problema (visto en la práctica):** el instalador de Ubuntu Server crea un
volumen lógico de ~100 GB y **deja el resto del Volume Group sin asignar**, para
que el usuario pueda crear otros volúmenes (`/home`, `/var`, `/docker`...). En un
homelab no queremos eso: queremos toda la capacidad en `/`. La última migración
nos obligó a expandir el LVM a mano — esto no debería volver a pasar.

- [x] `storage.sh` detecta espacio libre en el VG (`vgs` → `VFree > 0`) y que la
  raíz esté sobre LVM.
- [x] Si hay espacio, muestra VG, GB libres y ofrece expandir automáticamente:
  `sudo lvextend -l +100%FREE -r <LV-de-raíz>` (`-r` redimensiona el filesystem
  en el mismo paso). Idempotente: si no hay `VFree`, no hace nada.
- [ ] `healthcheck.sh` marca con ⚠ cuando hay espacio sin asignar en el VG y
  ofrece "reparar" (correr la expansión) desde el propio informe.

### v0.10 — Migración asistida (disco viejo automático)

**Objetivo (el norte del proyecto):** servidor recién instalado + disco viejo
conectado por USB → toda la migración desde el HLI, sin comandos a mano. Esto es
lo que vuelve al HLI un instalador "completo": que un equipo nuevo herede al
anterior en minutos.

- [x] Detectar discos conectados que NO sean el del sistema (`lsblk`), con
  dry-run que muestra tamaño/modelo para confirmar.
- [x] Activar el LVM del disco viejo (`vgchange -ay`) y **resolver la colisión
  de nombres**: si el VG viejo se llama igual que el del sistema, renombrarlo por
  UUID (`vgrename <UUID> oldvg`) automáticamente, con confirmación.
- [x] Montar la raíz del disco viejo (auto-detectada por `/etc`) y pasársela al
  helper de restauración sin que el usuario tipee la ruta.
- [x] Al terminar: desmontar y desactivar el VG viejo de forma limpia (trap).
- [x] `media-transfer`: copiar carpetas de media seleccionadas del disco viejo
  (muestra tamaño), accesible solo desde el menú Respaldos. Las "herramientas"
  (`HLI-TIPO: tool`) ya no aparecen en la instalación completa ni personalizada.
- [x] Guardas de seguridad: nunca tocar el disco del sistema; montaje en SOLO
  LECTURA; identificación por UUID; confirmación antes de renombrar VG o restaurar.

### v1.0 — Release

- [ ] README completo, `CHANGELOG.md`, `docs/`.
- [ ] Prueba de migración end-to-end en menos de 30 minutos.
- [ ] Etiqueta `v1.0`.
