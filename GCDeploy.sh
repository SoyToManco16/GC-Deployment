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
    error "El archivo de configuración no existe, abortando..."
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
sudo apt install -y \
  python3-openstackclient \
  mariadb-server python3-pymysql \
  rabbitmq-server \
  memcached python3-memcache \
  apache2 libapache2-mod-wsgi-py3 \
  keystone glance \
  nova-api nova-scheduler nova-conductor nova-compute nova-novncproxy \
  neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent \
  neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent \
  cinder-api cinder-scheduler cinder-volume lvm2 \
  openstack-dashboard \
  crudini \
  chrony \
  bridge-utils net-tools jq ethtool lsof tcpdump

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
    sudo mysql -u root -p"$DB_ROOT_PASS" <<EOF

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

# --------------------------------------------- #
#    Configuración de servicios de OpenStack    #
# --------------------------------------------- #

# ---------------- KEYSTONE ------------------

# Configurar Keystone (Servicio de identidad)
info "Configurando Keystone..."
sudo crudini --set /etc/keystone/keystone.conf database connection "mysql+pymysql://$KEYSTONE_DBUSER:$KEYSTONE_DBPASS@$DB_HOST/$KEYSTONE_DB"

# Configurar claves Fernet
info "Configurando claves Fernet..."
sudo crudini --set /etc/keystone/keystone.conf token provider fernet
sudo crudini --set /etc/keystone/keystone.conf token expiration 3600

info "Inicializando claves Fernet..."
sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

# Sincronizar con la BBDD
info "Sincronizando con la BBDD..."
sudo keystone-manage db_sync

# Inicializar Keystone
info "Inicializando Keystone..."
sudo keystone-manage bootstrap \
  --bootstrap-password "$OS_PASSWORD" \
  --bootstrap-admin-url http://$HOSTNAME:5000/v3/ \
  --bootstrap-internal-url http://$HOSTNAME:5000/v3/ \
  --bootstrap-public-url http://$HOSTNAME:5000/v3/ \
  --bootstrap-region-id RegionOne

# Reiniciar Apache2
sudo systemctl enable apache2
sudo systemctl restart apache2

# Verificar si está funcionando
if curl -s http://$HOSTNAME:5000/v3/ | grep -q "version"; then
    ok "Keystone responde correctamente en http://$HOSTNAME:5000/v3/"
else
    error "Keystone no está respondiendo correctamente. Revisa la configuración de Apache y el servicio de Keystone."
    exit 1
fi

# Todo OK !!
ok "Keystone instalado y configurado correctamente"

# ---------------------- CONFIGURACIÓN DE LA BASE DE DATOS ----------------------

info "Configurando la base de datos de Glance..."
sudo crudini --set /etc/glance/glance-api.conf database connection "mysql+pymysql://$GLANCE_DBUSER:$GLANCE_DBPASS@$DB_HOST/$GLANCE_DB" || error "Error al configurar la base de datos."

# ---------------------- CONFIGURACIÓN DE AUTHENTICACIÓN KEYSSTONE ----------------------

info "Configurando autenticación Keystone..."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken www_authenticate_uri http://$HOSTNAME:5000 || error "Error al configurar www_authenticate_uri."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://$HOSTNAME:5000/v3 || error "Error al configurar auth_url."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers $HOSTNAME:11211 || error "Error al configurar memcached_servers."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_type password || error "Error al configurar auth_type."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name Default || error "Error al configurar project_domain_name."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name Default || error "Error al configurar user_domain_name."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name service || error "Error al configurar project_name."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken username $GLANCE_USER || error "Error al configurar username."
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken password $GLANCE_PASS || error "Error al configurar password."

# ---------------------- CONFIGURACIÓN DE PASTE DEPLOY ----------------------

sudo crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone || error "Error al configurar paste_deploy."

# ---------------------- CONFIGURACIÓN DE ALMACENAMIENTO LOCAL ----------------------

info "Configurando almacenamiento local de imágenes..."
sudo crudini --set /etc/glance/glance-api.conf glance_store stores file,http || error "Error al configurar stores."
sudo crudini --set /etc/glance/glance-api.conf glance_store default_store file || error "Error al configurar default_store."
sudo crudini --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/ || error "Error al configurar filesystem_store_datadir."

# ---------------------- SINCRONIZACIÓN DE LA BASE DE DATOS ----------------------

info "Sincronizando la base de datos de Glance..."
sudo glance-manage db_sync || error "Error al sincronizar la base de datos."

# ---------------------- REINICIO DE LOS SERVICIOS ----------------------

info "Reiniciando servicios de Glance..."
sudo systemctl restart glance-api || error "Error al reiniciar glance-api."
sudo systemctl enable glance-api || error "Error al habilitar glance-api."

# ---------------------- REGISTRO EN KEYSTONE ----------------------

info "Registrando el servicio Glance en Keystone..."

# Crear usuario glance en Keystone (si no existe)
openstack user show $GLANCE_USER &>/dev/null || openstack user create --domain default --password "$GLANCE_PASS" $GLANCE_USER || error "Error al crear usuario glance."

# Darle rol de admin al usuario glance en el proyecto service
openstack role add --project service --user $GLANCE_USER admin || error "Error al asignar rol al usuario glance."

# Registrar el servicio glance (si no existe)
openstack service show image &>/dev/null || openstack service create --name glance --description "OpenStack Image" image || error "Error al registrar el servicio Glance."

# Crear los endpoints de Glance (si no existen)
openstack endpoint list --service image | grep -q 'public' || (
  openstack endpoint create --region RegionOne image public http://$HOSTNAME:9292 || error "Error al crear endpoint público."
  openstack endpoint create --region RegionOne image internal http://$HOSTNAME:9292 || error "Error al crear endpoint interno."
  openstack endpoint create --region RegionOne image admin http://$HOSTNAME:9292 || error "Error al crear endpoint de administración."
)

ok "Glance registrado correctamente en Keystone."

# ---------------------- COMPROBAR EL SERVICIO ----------------------

info "Comprobando que Glance está funcionando..."
if systemctl is-active --quiet glance-api; then
  ok "Glance instalado y configurado correctamente."
else
  error "Glance no está funcionando correctamente."
fi






# Revisar glance 





# Configurar servicios para máxima seguridad
if [ $CONFIG_TYPE == "1" ]; then
    info "Configurando para mayor seguridad"
    sudo ./GCMaxSecurity.sh
else 
    info "Continuando con el despliegue"
fi
