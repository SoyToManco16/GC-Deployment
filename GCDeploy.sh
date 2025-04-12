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

# Comprobar el tipo de configuración
if [ "$1" == "0" ]; then
  info "Bienvenido a GCDeploy"
  CONFIG_TYPE=0
elif [ "$1" == "1" ]; then
  info "Bienvenido a GCDeployMaxSecured"
  CONFIG_TYPE=1
else
  error "Falta un argumento, modo de uso 'sudo ./GCDeploy.sh <0/1>'"
  exit 1
fi

# Mostrar info por pantalla
info "Cargando archivo de configuración\n"

# Comprobar si el archivo de configuración existe
if [[ -f ./gc_env.conf ]]; then
    source ./gc_env.conf
    ok "Variables de entorno configuradas correctamente\n"
else
    error "El archivo no existe, abortando..."
    exit
fi

# Mostrar info del despliegue por pantalla
info "Desplegando como: $OS_USERNAME"
info "Nombre del proyecto: $OS_PROJECT_NAME\n"

# Añadir hostname si no está
info "Añadiendo hostname a /etc/hosts\n"

if ! grep -q "127.0.0.1  $HOSTNAME" /etc/hosts; then
  echo "127.0.0.1  $HOSTNAME" >> /etc/hosts
fi

# Añadir repositorio de OpenStack
info "Añadiendo repositorio de OpenStack"
if ! grep -q "cloud-archive:caracal" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
  sudo add-apt-repository -y cloud-archive:caracal
fi

# Actualizar sistema
info "Actualizando sistema e instalando dependencias\n"
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
info "Configurando chrony\n"
if systemctl is-active --quiet chrony; then
    sudo systemctl enable --now chrony
    chronyc sources; echo ""
    ok "Chrony configurado con éxito"
else 
    error "Chrony no está funcionando"
    exit 1 
fi

# Preparar cola de mensajería
info "Configurando RabbitMQ (Cola de mensajería)"
sudo systemctl enable --now rabbitmq-server
sudo systemctl start rabbitmq-server

if systemctl is-active --quiet rabbitmq-server; then
    sudo rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"
    sudo rabbitmqctl set_permissions "$RABBITMQ_USER" ".*" ".*" ".*"

    ok "RabbitMQ configurado con éxito"
    info "Usuarios de RabbitMQ: $(sudo rabbitmqctl list_users)"
    info "Permisos de los usuarios de RabbitMQ: $(sudo rabbitmqctl list_permissions)"
else 
    error "RabbitMQ no está funcionando"
    exit 1
fi



# Preparar bases de datos
info "Configurando MariaDB"

# Archivo de configuración de mariadb
sudo tee /etc/mysql/mariadb.conf.d/99-openstack.cnf <<EOF
[mysqld]
bind-address = 0.0.0.0
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

sudo systemctl restart mariadb
sudo systemctl enable --now mariadb

if systemctl is-active --quiet mariadb; then

    # Crear bases de datos y usuarios y permisos
    mysql -u root -p"$DB_ROOT_PASS" -h "localhost" <<EOF

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
    ok "MariaDB configurada con éxito"
else 
    error "MariaDB no está funcionando"
    exit 1
fi

# Preparar memcached
info "Configurando memcached"
if systemctl is-active --quiet memcached; then
  sudo sed -i 's/^# -l 127.0.0.1/-l 127.0.0.1/' /etc/memcached.conf
  sudo systemctl enable memcached
  sudo systemctl restart memcached
    ok "Memcached configurado con éxito"
else
  error "Memcached no está funcionando"
  exit 1
fi

# Configurar servicios para máxima seguridad
if [ $CONFIG_TYPE == "1" ]; then
    info "Configurando para mayor seguridad"
    sudo ./GCMaxSecurity.sh
else 
    info "Continuando con el despliegue"
fi



