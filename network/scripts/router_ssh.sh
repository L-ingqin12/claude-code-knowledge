#!/bin/bash
SSH="/d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/ssh"
SSHPASS="[已脱敏]"
SSH_OPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o MACs=+hmac-sha1-96,hmac-sha1,hmac-md5 -o StrictHostKeyChecking=no -o ConnectTimeout=8"
exec "$SSHPASS" -p "root" "$SSH" $SSH_OPTS root@[IP已脱敏] "$@"
