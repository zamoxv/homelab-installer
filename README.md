# HomeLab Installer

Instalador TUI para preparar un servidor doméstico Ubuntu Server.

Servicios incluidos en v0.2:

- Base Ubuntu
- Wake-on-LAN
- Estructura `/srv`
- Samba
- Jellyfin
- qBittorrent-nox
- AdGuard Home
- Estado de servicios
- Logs
- Restore básico

JASJIC queda fuera porque ya tiene sus propios scripts.

## Uso rápido

```bash
sudo apt update
sudo apt install -y git dialog
git clone https://github.com/zamoxv/homelab-installer.git
cd homelab-installer
chmod +x bootstrap.sh
./bootstrap.sh
```

## Uso sin GitHub

```bash
unzip homelab-installer-v0.2.zip
cd homelab-installer-v0.2
chmod +x bootstrap.sh modules/*.sh ui/*.sh lib/*.sh
./bootstrap.sh
```

## Accesos

- Jellyfin: `http://IP_SERVIDOR:8096`
- qBittorrent: `http://IP_SERVIDOR:8080`
- AdGuard Home: `http://IP_SERVIDOR:3000`
- Samba: `smb://IP_SERVIDOR/peliculas`

## Carpetas

```text
/srv/media/peliculas
/srv/media/series
/srv/media/musica
/srv/media/libros
/srv/media/fotos
/srv/media/videos
/srv/media/downloads
/srv/media/transcode
/srv/backups
/srv/config
/srv/restore
```
