# Proxmox Template Generator For Tenantos

Execute the script directly on the Proxmox host. Automated and interactive mode available.

## Requirements

```
apt update && apt install libguestfs-tools
```

## Usage

Run `./generate.sh --help` for all options.

Start with the interactive mode - it will generate a CLI command for automated builds.

## Cloud Image Sources

- **Debian**: https://cloud.debian.org/images/cloud/
- **Ubuntu**: https://cloud-images.ubuntu.com/
- **CentOS**: https://cloud.centos.org/centos/
- **AlmaLinux**: https://repo.almalinux.org/almalinux/
- **Rocky Linux**: https://download.rockylinux.org/pub/rocky/
- **Fedora**: https://fedoraproject.org/cloud/download/

## Further Information

https://documentation.tenantos.com/Tenantos/virtualization/template-installations-proxmox/#creating-templates

## License

MIT License - Copyright (c) 2025 Tenantos
