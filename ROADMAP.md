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

- [ ] `modules/power.sh`: desactivar suspensión/hibernación/hybrid-sleep,
  ignorar cierre de tapa en `logind.conf`, verificar swap/hibernación, revisar
  timers de suspensión.
- [ ] Perfil de servidor (`24/7` / `Escritorio` / `Notebook`) que en un solo
  paso agrupa: nunca suspender, ignorar tapa, WOL, ajustar `journald`,
  `fstrim.timer` si hay SSD, `smartd` si hay HDD.

### v0.6 — Health Check

- [ ] `modules/healthcheck.sh`: informe de SMART de discos, temperatura, RAM,
  espacio libre, estado de servicios, IP, DNS, puertos abiertos y uptime.

### v0.7 — Backup y Restore de migración

- [ ] `modules/backup.sh`: genera `backup-YYYY-MM-DD.tar.gz` con Jellyfin,
  Samba, qBittorrent, configuración y un `config.yml` exportable.
- [ ] Restore robusto de migración (más allá del básico actual).

### v0.8 — Experiencia / Producto

- [ ] Dashboard enriquecido: hostname, distro, IP, disco, memoria, estado de
  servicios y barra de espacio.
- [ ] Barra de progreso por instalación.
- [ ] Detección automática: interfaz de red y hardware (modelo, CPU, RAM, disco).
- [ ] Modo actualización: `apt update`/`upgrade`, limpieza de paquetes y cachés,
  reinicio de servicios cuando corresponde.

### v1.0 — Release

- [ ] README completo, `CHANGELOG.md`, `docs/`.
- [ ] Prueba de migración end-to-end en menos de 30 minutos.
- [ ] Etiqueta `v1.0`.
