# Ragtech UPS — Docker/NUT

Docker-based Network UPS Tools (NUT) server with
support for Ragtech USB CDC-ACM UPS devices.

## Requirements

- Linux host with Docker Engine and Docker Compose
- Compatible Ragtech USB UPS
- USB serial device such as /dev/ttyACM0

## Build

From the repository root:

docker build --platform linux/amd64 \
  -f docker/Dockerfile \
  -t ragtech-nut:local .

## Configuration

1. Review docker/config/ups.conf.example
2. Review docker/config/upsd.conf.example
3. Review docker/config/upsd.users.example
4. Adjust the USB device path in compose.example.yml

The default NUT port is 3493.

## Start

On a compatible Linux host with the UPS connected:

docker compose -f docker/compose.example.yml up -d

## Check

docker compose -f docker/compose.example.yml logs

The NUT server must be reachable before clients
can query UPS variables.

## Security

The example binds the NUT server to 127.0.0.1.
Do not expose port 3493 directly to the internet.

## Limitations

The Ragtech driver is experimental.

Validate device compatibility, battery reporting
and shutdown behavior before enabling automatic shutdown.
