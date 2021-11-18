#!/usr/bin/env bash
#
# Based on the following repo below
# https://github.com/puckel/docker-airflow


# ocp random uid fix
# /etc/passwd
if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
      #kludge: can only write /etc/passwd NOT /etc
      sed "/^${USER_NAME:-default}/d" /etc/passwd > /tmp/passwd
      cat /tmp/passwd > /etc/passwd && rm /tmp/passwd
      echo "${USER_NAME:-airflow}:x:$(id -u):0:${USER_NAME:-airflow} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

# nss_wrapper
USER_ID=$(id -u)

if [ x"$USER_ID" != x"0" -a x"$USER_ID" != x"1001" -a -e /usr/lib64/libnss_wrapper.so ]; then
    NSS_WRAPPER_PASSWD=/tmp/passwd.nss_wrapper
    NSS_WRAPPER_GROUP=/etc/group

    cp /etc/passwd $NSS_WRAPPER_PASSWD

    echo "${USER_NAME:-airflow}:x:$(id -u):0:${USER_NAME:-airflow} user:${HOME}:/sbin/nologin" >> $NSS_WRAPPER_PASSWD

    export NSS_WRAPPER_PASSWD
    export NSS_WRAPPER_GROUP

    export LD_PRELOAD=/usr/lib64/libnss_wrapper.so

fi

# User-provided configuration must always be respected.
#
# Therefore, this script must only derives Airflow AIRFLOW__ variables from other variables
# when the user did not provide their own configuration.

# Global defaults and back-compat
: "${AIRFLOW_HOME:="/opt/app-root/src"}"
: "${AIRFLOW__CORE__DAGS_FOLDER:="${AIRFLOW_HOME}/dags"}"
: "${AIRFLOW__CORE__BASE_LOG_FOLDER:="${AIRFLOW_HOME}/logs"}"
: "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}}"
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Sequential}Executor}"
: "${AIRFLOW__WEBSERVER__SECRET_KEY:=${SECRET_KEY:=$(openssl rand -hex 32)}}"

# Load DAGs examples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]; then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi

export \
  AIRFLOW_HOME \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \
  AIRFLOW__WEBSERVER__SECRET_KEY

# TODO: document in README
# add custom path for modules in ${AIRFLOW_HOME}/dags/scripts
export PYTHONPATH=${AIRFLOW__CORE__DAGS_FOLDER}/scripts:${PYTHONPATH}

# TODO: document in README
# Allow PIP to cache
# See $HOME/.cache/pip
unset PIP_NO_CACHE_DIR

# TODO: document in README
# Install custom python package if requirements.txt is present
if [ -e "/config/requirements.txt" ]; then
    echo "KLUDGE: pip install -r /config/requirements.txt via entrypoint.sh"
    $(command -v pip) install -r /config/requirements.txt
fi

# TODO: document in README
# Install custom airflow.cfg (better to use env)
if [ -e "/config/airflow.cfg" ]; then
    cp /config/airflow.cfg ${AIRFLOW_HOME}/
fi

# Other executors than SequentialExecutor drive the need for an SQL database, here PostgreSQL is used
if [ "$AIRFLOW__CORE__EXECUTOR" != "SequentialExecutor" ]; then
  # Check if the user has provided explicit Airflow configuration concerning the database
  if [ -z "$AIRFLOW__CORE__SQL_ALCHEMY_CONN" ]; then
    # Default values corresponding to the default compose files
    : "${POSTGRES_HOST:="postgres"}"
    : "${POSTGRES_PORT:="5432"}"
    : "${POSTGRES_USER:="airflow"}"
    : "${POSTGRES_PASSWORD:="airflow"}"
    : "${POSTGRES_DB:="airflow"}"
    : "${POSTGRES_EXTRAS:-""}"

    AIRFLOW__CORE__SQL_ALCHEMY_CONN="postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}${POSTGRES_EXTRAS}"
    export AIRFLOW__CORE__SQL_ALCHEMY_CONN

    # Check if the user has provided explicit Airflow configuration for the broker's connection to the database
    if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
      AIRFLOW__CELERY__RESULT_BACKEND="db+postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}${POSTGRES_EXTRAS}"
      export AIRFLOW__CELERY__RESULT_BACKEND
    fi
  else
    if [[ "$AIRFLOW__CORE__EXECUTOR" == "CeleryExecutor" && -z "$AIRFLOW__CELERY__RESULT_BACKEND" ]]; then
      >&2 printf '%s\n' "FATAL: if you set AIRFLOW__CORE__SQL_ALCHEMY_CONN manually with CeleryExecutor you must also set AIRFLOW__CELERY__RESULT_BACKEND"
      exit 1
    fi

    # Derive useful variables from the AIRFLOW__ variables provided explicitly by the user
    POSTGRES_ENDPOINT=$(echo -n "$AIRFLOW__CORE__SQL_ALCHEMY_CONN" | cut -d '/' -f3 | sed -e 's,.*@,,')
    POSTGRES_HOST=$(echo -n "$POSTGRES_ENDPOINT" | cut -d ':' -f1)
    POSTGRES_PORT=$(echo -n "$POSTGRES_ENDPOINT" | cut -d ':' -f2)
  fi
fi

# CeleryExecutor drives the need for a Celery broker, here Redis is used
if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
  # Check if the user has provided explicit Airflow configuration concerning the broker
  if [ -z "$AIRFLOW__CELERY__BROKER_URL" ]; then
    # Default values corresponding to the default compose files
    : "${REDIS_PROTO:="redis://"}"
    : "${REDIS_HOST:="redis"}"
    : "${REDIS_PORT:="6379"}"
    : "${REDIS_PASSWORD:=""}"
    : "${REDIS_DBNUM:="1"}"

    # When Redis is secured by basic auth, it does not handle the username part of basic auth, only a token
    if [ -n "$REDIS_PASSWORD" ]; then
      REDIS_PREFIX=":${REDIS_PASSWORD}@"
    else
      REDIS_PREFIX=
    fi

    AIRFLOW__CELERY__BROKER_URL="${REDIS_PROTO}${REDIS_PREFIX}${REDIS_HOST}:${REDIS_PORT}/${REDIS_DBNUM}"
    export AIRFLOW__CELERY__BROKER_URL
  else
    # Derive useful variables from the AIRFLOW__ variables provided explicitly by the user
    REDIS_ENDPOINT=$(echo -n "$AIRFLOW__CELERY__BROKER_URL" | cut -d '/' -f3 | sed -e 's,.*@,,')
    REDIS_HOST=$(echo -n "$POSTGRES_ENDPOINT" | cut -d ':' -f1)
    REDIS_PORT=$(echo -n "$POSTGRES_ENDPOINT" | cut -d ':' -f2)
  fi
fi

# main
case "$1" in
  webserver)
    airflow db init
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ] || \
       [ "$AIRFLOW__CORE__EXECUTOR" = "SequentialExecutor" ]; then
      # With the "Local" and "Sequential" executors it should all run in one container.
      airflow scheduler &
    fi
    exec airflow webserver
    ;;
  worker|scheduler)
    # Give the webserver time to run 'db init'
    sleep 10
    exec airflow "$@"
    ;;
  flower)
    sleep 10
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  run)
    # super kludge mode on
    # see Dockerfile for ENV PATH_KLUDGE
    export PATH=${PATH_KLUDGE//'/usr/local/bin'//}
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac
