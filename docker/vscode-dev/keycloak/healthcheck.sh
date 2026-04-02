#!/bin/bash
# Keycloak readiness check — uses bash TCP since curl is not available in the image.
# Returns 0 when the prodbox realm is importerd and serving, 1 otherwise.
set -e
exec 3<>/dev/tcp/localhost/8080
printf 'GET /auth/realms/prodbox HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
read -r -t 3 response <&3
exec 3>&-
[[ "$response" == *"200"* ]]
