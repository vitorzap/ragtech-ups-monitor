# NoBrkMon Configuration

NoBrkMon is a native macOS UPS monitoring application.

It communicates directly with a Network UPS Tools (NUT)
server over TCP.

## Configuration file

The application reads:

~/.config/nobreak-monitor/config.json

On first launch, a default file is created if it does not exist.

## Example

{
  "target": "ragtech700@192.0.2.10:3493",
  "pollIntervalSeconds": 5
}

Replace the example address with your NUT server's IP address
or hostname, and adjust the port.

The default NUT TCP port is 3493.

## Target format

UPS_NAME@SERVER_HOST:PORT

For example:

myups@nut-server.local:3493

## Additional settings

The application supports alarm settings and configurable
measurement thresholds in config.json.

Do not commit personal configuration files or credentials.
