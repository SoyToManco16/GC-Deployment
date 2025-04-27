#!/bin/bash

# Comprobar que se pasa un argumento
if [ -z "$1" ]; then
    echo -e "Error: Debes introducir un nombre de usuario."
    exit 1
fi

# Crear usuario con `useradd`
sudo useradd -m -s /bin/bash "$1"

# Asignar una contraseña (puedes modificar esto según lo necesites)
echo "$1:password" | sudo chpasswd

# Añadir al grupo sudo
sudo usermod -aG sudo "$1"

# Modificar sudoers con visudo
echo "$1 ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/$1 > /dev/null

# Contraseña
sudo passwd "$1"

# Exito
echo "El usuario $1 ha sido añadido al grupo sudoers"
