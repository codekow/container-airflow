# registry.redhat.io/rhscl/python-38-rhel7
# hadolint ignore=DL3006
FROM rhscl/python-38-rhel7

### Atomic/OpenShift Labels - https://github.com/projectatomic/ContainerApplicationGenericLabels
LABEL name="airflow" \
      maintainer="koree@redhat.com" \
      summary="airflow on OpenShift" \
      description="airflow on OpenShift"

# bug: hadolint doesn't see user below
# hadolint ignore=DL3002
USER root

ARG AIRFLOW_USER_HOME=/opt/app-root/src
ENV AIRFLOW_HOME=${AIRFLOW_USER_HOME}

# install airflow
COPY requirements.txt $AIRFLOW_USER_HOME
# hadolint ignore=DL3013
RUN $(which pip) install --upgrade pip && \
    pip install --no-cache-dir -U setuptools wheel && \
    pip install --no-cache-dir -r $AIRFLOW_USER_HOME/requirements.txt

# setup scripts
COPY bin/ /usr/local/bin/

# some kludges
ENV PATH_KLUDGE=$PATH
RUN chmod g+w /etc/passwd && \
    chmod 755 /usr/local/bin/entrypoint.sh && \
    chmod 755 /usr/local/bin/fix-permissions.sh && \
    fix-permissions.sh $APP_ROOT

USER 1001

EXPOSE 8080 5555 8793

WORKDIR ${AIRFLOW_USER_HOME}

ENTRYPOINT ["entrypoint.sh"]
CMD ["webserver"]