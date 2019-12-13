#!/bin/bash

function array_by_comma { local IFS=","; echo "$*"; }

# Wait for containers
while ! mysqladmin status --socket=/var/run/mysqld/mysqld.sock -u${DBUSER} -p${DBPASS} --silent; do
  echo "Waiting for SQL..."
  sleep 2
done

until [[ $(redis-cli -h redis-mailcow PING) == "PONG" ]]; do
  echo "Waiting for Redis..."
  sleep 2
done

# Set a default release format

if [[ -z $(redis-cli --raw -h redis-mailcow GET Q_RELEASE_FORMAT) ]]; then
  redis-cli --raw -h redis-mailcow SET Q_RELEASE_FORMAT raw
fi

# Set max age of q items - if unset

if [[ -z $(redis-cli --raw -h redis-mailcow GET Q_MAX_AGE) ]]; then
  redis-cli --raw -h redis-mailcow SET Q_MAX_AGE 365
fi

# Trigger db init
echo "Running DB init..."
php -c /usr/local/etc/php -f /web/inc/init_db.inc.php

# Recreating domain map
echo "Rebuilding domain map in Redis..."
declare -a DOMAIN_ARR
  redis-cli -h redis-mailcow DEL DOMAIN_MAP > /dev/null
while read line
do
  DOMAIN_ARR+=("$line")
done < <(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SELECT domain FROM domain" -Bs)
while read line
do
  DOMAIN_ARR+=("$line")
done < <(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SELECT alias_domain FROM alias_domain" -Bs)

if [[ ! -z ${DOMAIN_ARR} ]]; then
for domain in "${DOMAIN_ARR[@]}"; do
  redis-cli -h redis-mailcow HSET DOMAIN_MAP ${domain} 1 > /dev/null
done
fi

# Create dummy for custom overrides of mailcow style
[[ ! -f /web/css/build/0081-custom-mailcow.css ]] && echo '/* Autogenerated by mailcow */' > /web/css/build/0081-custom-mailcow.css

# Set API options if env vars are not empty

if [[ ${API_ALLOW_FROM} != "invalid" ]] && \
  [[ ${API_KEY} != "invalid" ]] && \
  [[ ! -z ${API_KEY} ]] && \
  [[ ! -z ${API_ALLOW_FROM} ]]; then
  IFS=',' read -r -a API_ALLOW_FROM_ARR <<< "${API_ALLOW_FROM}"
  declare -a VALIDATED_API_ALLOW_FROM_ARR
  REGEX_IP6='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'
  REGEX_IP4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

  for IP in "${API_ALLOW_FROM_ARR[@]}"; do
    if [[ ${IP} =~ ${REGEX_IP6} ]] || [[ ${IP} =~ ${REGEX_IP4} ]]; then
      VALIDATED_API_ALLOW_FROM_ARR+=("${IP}")
    fi
  done
  VALIDATED_IPS=$(array_by_comma ${VALIDATED_API_ALLOW_FROM_ARR[*]})
  if [[ ! -z ${VALIDATED_IPS} ]]; then
    mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} << EOF
DELETE FROM api;
INSERT INTO api (api_key, active, allow_from) VALUES ("${API_KEY}", "1", "${VALIDATED_IPS}");
EOF
  fi
fi

# Create events
mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} << EOF
DROP EVENT IF EXISTS clean_spamalias;
DELIMITER //
CREATE EVENT clean_spamalias
ON SCHEDULE EVERY 1 DAY DO
BEGIN
  DELETE FROM spamalias WHERE validity < UNIX_TIMESTAMP();
END;
//
DELIMITER ;
DROP EVENT IF EXISTS clean_oauth2;
DELIMITER //
CREATE EVENT clean_oauth2
ON SCHEDULE EVERY 1 DAY DO
BEGIN
  DELETE FROM oauth_refresh_tokens WHERE expires < NOW();
  DELETE FROM oauth_access_tokens WHERE expires < NOW();
  DELETE FROM oauth_authorization_codes WHERE expires < NOW();
END;
//
DELIMITER ;
EOF

# Run hooks
for file in /hooks/*; do
  if [ -x "${file}" ]; then
    echo "Running hook ${file}"
    "${file}"
  fi
done

exec "$@"
