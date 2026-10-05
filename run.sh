#!/usr/bin/env bash
cd "$(dirname "$0")" && ./update-firewall.sh -p 22,3306,27017,2083 "$@"
