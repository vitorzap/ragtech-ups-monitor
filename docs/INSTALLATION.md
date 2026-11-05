# Installation Guide

## Requirements

- Compatible Ragtech UPS with USB CDC-ACM interface
- Linux or QNAP host with Docker and Docker Compose
- USB serial device accessible to the container
- Optional Mac running the NoBrkMon monitoring application

## 1. Build the NUT image

From the repository root:

docker build --platform linux/amd64 \
  -f docker/Dockerfile \
  -t ragtech-nut:local .

The Dockerfile uses a pinned Network UPS Tools commit.

## 2. Configure NUT

Copy the example files:

cp docker/config/ups.conf.example docker/config/ups.conf
cp docker/config/upsd.conf.example docker/config/upsd.conf
cp docker/config/upsd.users.example docker/config/upsd.users

Replace the example password with a unique secret.
Adjust the UPS name and USB device path as required.

Keep local configuration files outside version control.

## 3. Configure Docker Compose

Review docker/compose.example.yml.

The example expects a Linux host with /dev/ttyACM0.
It is not directly suitable for a Mac without
USB device integration.

The example binds the published NUT port to localhost.

## 4. Start the server

On a supported Linux host with the UPS connected:

docker compose -f docker/compose.example.yml up -d

Check the logs and verify UPS values before deploying
automatic shutdown.

## 5. QNAP shutdown integration

Copy the QNAP scripts into a dedicated installation
directory on the NAS.

Create ups-config.conf from ups-config.conf.example.

Configure NUT monitoring and the installation's startup
mechanism.

Do not create enable-real-shutdown until the entire
installation has been reviewed and validated.

## 6. macOS monitoring

See macos/NoBrkMon/README.md and CONFIGURATION.md.

## Limitations

The complete public deployment procedure has not yet
been independently validated.

Do not assume this example is production-ready for
unverified UPS models, platforms, or Docker environments.
