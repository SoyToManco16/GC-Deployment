#!/bin/bash

# Comprobar que se pasan dos argumentos
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "Uso: $0 <nombre_usuario> <contraseña>"
    exit 1
fi

USUARIO="$1"
CONTRASEÑA="$2"

# Crear usuario con `useradd`
sudo useradd -m -s /bin/bash "$USUARIO"

# Asignar la contraseña
echo "$USUARIO:$CONTRASEÑA" | sudo chpasswd

# Añadir al grupo sudo
sudo usermod -aG sudo "$USUARIO"

# Modificar sudoers con visudo
echo "$USUARIO ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USUARIO > /dev/null

# Confirmación
echo "El usuario $USUARIO ha sido creado con acceso sudo sin contraseña."
