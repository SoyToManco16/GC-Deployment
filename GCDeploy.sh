#!/bin/bash

# --------------------------------------------- #
# Este script ha sido diseñado para el despliegue
# de OpenStack - Ejecutar como sudo
# Antes de continuar por favor compruebe su 
# hostname y netplan para evitar problemas
# una vez comenzado no hay vuelta atrás
# --------------------------------------------- #

# Evitar dolores de cabeza
set -e

# --------------------------------------------- #
# Funciones de color

info()    { echo -e "\e[36m[INFO]\e[0m $*"; }     # Cyan
ok()      { echo -e "\e[32m[OK]\e[0m $*"; }       # Verde
warn()    { echo -e "\e[33m[WARN]\e[0m $*"; }     # Amarillo
error()   { echo -e "\e[31m[ERROR]\e[0m $*"; }    # Rojo

# --------------------------------------------- #

# Mostrar info por pantalla
info "Bienvenido a GCDeploy"
info "Cargando archivo de configuración"

# Comprobar si el archivo de configuración existe
if [[ -f ./gc_env.conf ]]; then
    source ./gc_env.conf
    echo ""; ok "Variables de entorno configuradas correctamente"
else
    error "El archivo no existe, abortando..."
    exit
fi

# Mostrar info del despliegue por pantalla
echo ""
info "Desplegando como: $OS_USERNAME"
info "Nombre del proyecto: $OS_PROJECT_NAME"; echo ""

info "Añadiendo hostname a /etc/hosts"

if ! grep -q "127.0.0.1  $HOSTNAME" /etc/hosts; then
  echo "127.0.0.1  $HOSTNAME" >> /etc/hosts
fi

info "Actualizando sistema e instalando dependencias"

# Actualizar sistema
sudo apt update && sudo apt -y upgrade && sudo apt -y dist-upgrade

# Instalar dependencias
sudo apt update && sudo apt install -y \
  python3-openstackclient \
  mariadb-server python3-pymysql \
  rabbitmq-server \
  memcached python3-memcache \
  apache2 libapache2-mod-wsgi-py3 \
  keystone glance \
  nova-api nova-scheduler nova-conductor nova-compute \
  neutron-server neutron-linuxbridge-agent \
  cinder-api cinder-scheduler lvm2 \
  openstack-dashboard \
  crudini \
  chrony


# Preparar chrony
info "Configurando chrony"
sudo systemctl enable --now chrony
chronyc sources; echo ""

# Preparar bases de datos
info "Configurando BBDDs"
sudo mysql -u root -p"$DB_ROOT_PASS" -h "$DB_HOST" <<EOF

CREATE DATABASE IF NOT EXISTS $KEYSTONE_DB;
CREATE DATABASE IF NOT EXISTS $GLANCE_DB;
CREATE DATABASE IF NOT EXISTS $NOVA_DB;
CREATE DATABASE IF NOT EXISTS $NEUTRON_DB;
CREATE DATABASE IF NOT EXISTS $CINDER_DB;

CREATE USER IF NOT EXISTS '$KEYSTONE_DBUSER'@'$HOSTNAME' IDENTIFIED BY '$KEYSTONE_DBPASS';
CREATE USER IF NOT EXISTS '$GLANCE_DBUSER'@'$HOSTNAME' IDENTIFIED BY '$GLANCE_DBPASS';
CREATE USER IF NOT EXISTS '$NOVA_DBUSER'@'$HOSTNAME' IDENTIFIED BY '$NOVA_DBPASS';
CREATE USER IF NOT EXISTS '$NEUTRON_DBUSER'@'$HOSTNAME' IDENTIFIED BY '$NEUTRON_DBPASS';
CREATE USER IF NOT EXISTS '$CINDER_DBUSER'@'$HOSTNAME' IDENTIFIED BY '$CINDER_DBPASS';

GRANT ALL PRIVILEGES ON $KEYSTONE_DB.* TO '$KEYSTONE_DBUSER'@'$HOSTNAME';
GRANT ALL PRIVILEGES ON $GLANCE_DB.* TO '$GLANCE_DBUSER'@'$HOSTNAME';
GRANT ALL PRIVILEGES ON $NOVA_DB.* TO '$NOVA_DBUSER'@'$HOSTNAME';
GRANT ALL PRIVILEGES ON $NEUTRON_DB.* TO '$NEUTRON_DBUSER'@'$HOSTNAME';
GRANT ALL PRIVILEGES ON $CINDER_DB.* TO '$CINDER_DBUSER'@'$HOSTNAME';

FLUSH PRIVILEGES;
EOF

