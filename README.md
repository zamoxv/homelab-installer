# HomeLab Installer (HLI)

Instalador TUI (menú con `dialog`) para montar y mantener un servidor doméstico
sobre Ubuntu Server.

## Misión

Que migrar el servidor completo a un equipo nuevo (Lenovo M70q, Dell OptiPlex,
etc.) tome **menos de 30 minutos**. El HLI no es un script de conveniencia: es
el seguro de migración del homelab. Cada problema real que aparece administrando
el servidor se convierte en un módulo, para no volver a resolverlo a mano.

## Características

- **Plugin System**: el menú se construye solo leyendo `modules/`. Agregar una
  función nueva es tirar un archivo con su cabecera — sin tocar el resto.
- **Perfil de servidor** (`24/7` / `Escritorio` / `Notebook`): energía y
  mantenimiento en un paso (no suspender, ignorar tapa, WOL, journald, fstrim,
  smartd según SSD/HDD).
- **Backup y restore de migración**: empaqueta la configuración/estado (sin la
  media) y restaura desde un backup HLI o desde un disco viejo montado.
- **Health Check**: informe de discos (SMART), temperatura, RAM, espacio,
  servicios, IP, DNS, puertos y uptime.
- **Dashboard** con detección de hardware (modelo, CPU, RAM, disco, distro).
- **Barra de progreso** en la instalación completa, con `apt` no-interactivo.

## Uso rápido

```bash
sudo apt update
sudo apt install -y git dialog
git clone <URL-del-repo> homelab-installer
cd homelab-installer
chmod +x bootstrap.sh modules/*.sh ui/*.sh lib/*.sh
./bootstrap.sh
```

Al arrancar pide la contraseña de `sudo` una vez (la mantiene viva durante toda
la sesión para que los módulos en segundo plano no se cuelguen).

## Menú principal

| # | Opción |
|---|--------|
| 1 | Dashboard del servidor |
| 2 | Instalación completa recomendada (con barra de progreso) |
| 3 | Instalación personalizada (salida de `apt` visible) |
| 4 | Perfil de servidor (energía y mantenimiento) |
| 5 | Configurar Samba + carpetas |
| 6 | Configurar disco de datos (montaje permanente por UUID) |
| 7 | Respaldos y migración (crear / restaurar `.tar.gz` / disco viejo) |
| 8 | Actualizar servidor |
| 9 | Estado de servicios |
| 10 | Diagnóstico (Health Check) |
| 11 | Salir |

## Módulos

Descubiertos automáticamente y ordenados por `HLI-ORDER`:

| Módulo | Descripción | En "completa" |
|--------|-------------|:---:|
| `update` | Actualizar el servidor (apt + limpieza) | — |
| `base` | Paquetes base y utilidades | ✅ |
| `storage` | Estructura `/srv` + expansión de LVM | ✅ |
| `datadisk` | Configurar disco de datos permanente | — |
| `power` | Gestión de energía (no suspender, ignorar tapa) | ✅ |
| `wol` | Wake-on-LAN | ✅ |
| `samba` | Samba + carpetas compartidas | ✅ |
| `jellyfin` | Servidor multimedia Jellyfin | ✅ |
| `qbittorrent` | qBittorrent-nox como servicio | ✅ |
| `adguard` | AdGuard Home | ✅ |
| `migrate` | Restaurar config desde un disco viejo (automático) | — |
| `media-transfer` | Transferir media desde un disco viejo (automático) | — |
| `restore` | Restaurar desde un backup (.tar.gz) | — |
| `backup` | Backup de configuración y estado | — |
| `status` | Ver estado de servicios | — |
| `healthcheck` | Diagnóstico del servidor | — |

Los módulos con `—` son **herramientas** (`HLI-TIPO: tool`): no aparecen en la
instalación completa ni en la personalizada; se usan desde su menú (Respaldos,
Estado, Diagnóstico, Actualizar).

## Cómo agregar un módulo

1. Creá `modules/mimodulo.sh` con la cabecera de metadata:

   ```bash
   #!/usr/bin/env bash
   # HLI-MODULE: mimodulo
   # HLI-DESC: Lo que hace, breve
   # HLI-ORDER: 65
   # HLI-DEFAULT: yes      # entra en "instalación completa" y viene pre-marcado
   # HLI-TIPO: install     # 'tool' = herramienta (no aparece en instalación)
   # HLI-TUI: no           # yes si usa dialog/prompts (hereda la terminal)
   set -euo pipefail
   source "$(dirname "$0")/../lib/common.sh"

   # ... tu lógica idempotente ...

   mark_done mimodulo
   ```

2. `chmod +x modules/mimodulo.sh`.
3. Listo: aparece solo en el menú y en la instalación. No se toca nada más.

## Estructura

```text
bootstrap.sh        # punto de entrada
lib/common.sh       # helpers, plugin system, detección de hardware
ui/menu.sh          # menú, dashboard, perfil, instalación
modules/*.sh        # un archivo por capacidad (auto-descubiertos)
config/default.conf # rutas y valores por defecto
ROADMAP.md          # plan por fases
```

## Carpetas creadas

```text
/srv/media/{peliculas,series,musica,libros,fotos,videos,downloads,transcode}
/srv/backups   /srv/config   /srv/restore
```

## Roadmap

El plan por fases está en [ROADMAP.md](ROADMAP.md). Es un proyecto vivo: cada
servidor que montamos lo mejora un poco más.
