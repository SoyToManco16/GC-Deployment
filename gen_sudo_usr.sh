#!/bin/bash

# Colores
RED='\e[31m'
GREEN='\e[32m'
NC='\e[0m' # Reset color

# Comprobar que se pasa un argumento
if [ -z "$1" ]; then
    echo -e "${RED}Error: Debes introducir un nombre de usuario.${NC}"
    exit 1
fi

# Añadir usuario
sudo adduser "$1"
sudo usermod -aG sudo "$1"

# Modificar sudoers con visudo
echo "$1 ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/$1 > /dev/null

echo -e "${GREEN}Usuario '$1' creado, añadido al grupo sudo y configurado para usar sudo sin contraseña.${NC}"
