# Security

## Network

NUT should only be accessible from trusted systems.
Do not expose TCP port 3493 directly to the internet.

## Credentials

Do not commit:
- Real NUT account passwords
- SSH private keys
- Local configuration files
- Authorization files
- Operational logs containing private information

## Remote shutdown

Use a dedicated SSH key with restricted authorized_keys
permissions and a narrowly scoped sudoers rule.

Avoid granting unrestricted remote shell or sudo access.

## Shutdown safety

Automatic shutdown is disabled by default in the
QNAP integration until explicitly authorized.

Validate device status, communications, battery
reporting, and operating system shutdown behavior
before enabling real shutdown.

## Reporting vulnerabilities

Until a dedicated security reporting process is
configured, do not publish sensitive vulnerability
details in public GitHub Issues.
