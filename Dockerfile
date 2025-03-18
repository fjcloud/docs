# Django impress
# ---- base image to inherit from ----
FROM registry.redhat.io/ubi9/python-312 AS base

# ---- Back-end builder image ----
FROM base AS back-builder
WORKDIR /builder
# Copy required python dependencies
COPY ./src/backend /builder
# Create install directory with proper permissions for OpenShift
RUN mkdir -p /tmp/install && \
  pip install --prefix=/tmp/install . && \
  mkdir -p /install && \
  cp -r /tmp/install/* /install/ || true

# ---- mails ----
FROM registry.redhat.io/ubi9/nodejs-20 AS mail-builder
COPY ./src/mail /mail/app
WORKDIR /mail/app
# Install yarn first
RUN npm install -g yarn && \
    yarn install --frozen-lockfile && \
    yarn build

# ---- static link collector ----
FROM base AS link-collector
ARG IMPRESS_STATIC_ROOT=/data/static
# Install pango
RUN dnf install -y pango
# Copy installed python dependencies
COPY --from=back-builder /install /usr/local
# Copy impress application (see .dockerignore)
COPY ./src/backend /app/
WORKDIR /app
# collectstatic
RUN DJANGO_CONFIGURATION=Build \
    python manage.py collectstatic --noinput

# ---- Core application image ----
FROM base AS core
ENV PYTHONUNBUFFERED=1
# Install required system libs
RUN dnf install -y \
  cairo \
  gettext \
  gdk-pixbuf2 \
  libffi-devel \
  pango \
  shared-mime-info \
  postgresql-client
RUN wget https://svn.apache.org/repos/asf/httpd/httpd/trunk/docs/conf/mime.types -O /etc/mime.types

# Copy entrypoint
COPY ./docker/files/usr/local/bin/entrypoint /usr/local/bin/entrypoint

# Give the root group the same permissions as the root user on directories
# OpenShift runs containers with a random UID and GID of 0 (root group)
RUN chmod g=u /etc/passwd && \
    mkdir -p /data/static /data/media && \
    chmod -R g=u /data && \
    chmod -R g=u /app

# Copy installed python dependencies
COPY --from=back-builder /install /usr/local

# Copy impress application (see .dockerignore)
COPY ./src/backend /app/
WORKDIR /app

# Generate compiled translation messages
RUN DJANGO_CONFIGURATION=Build \
    python manage.py compilemessages

# We wrap commands run in this container by the following entrypoint that
# creates a user on-the-fly with the container user ID and root group ID.
ENTRYPOINT [ "/usr/local/bin/entrypoint" ]

# ---- Development image ----
FROM core AS backend-development

# Uninstall impress and re-install it in editable mode along with development
# dependencies
RUN pip uninstall -y impress
RUN pip install -e .[dev]

# Target database host (e.g. database engine following docker compose services
# name) & port
ENV DB_HOST=postgresql \
    DB_PORT=5432

# Run django development server
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]

# ---- Production image ----
FROM core AS backend-production
ARG IMPRESS_STATIC_ROOT=/data/static

# Gunicorn
RUN mkdir -p /usr/local/etc/gunicorn
COPY docker/files/usr/local/etc/gunicorn/impress.py /usr/local/etc/gunicorn/impress.py

# Copy statics
COPY --from=link-collector ${IMPRESS_STATIC_ROOT} ${IMPRESS_STATIC_ROOT}

# Copy impress mails
COPY --from=mail-builder /mail/backend/core/templates/mail /app/core/templates/mail

# Make sure permissions are set correctly for OpenShift
RUN chgrp -R 0 /app ${IMPRESS_STATIC_ROOT} && \
    chmod -R g=u /app ${IMPRESS_STATIC_ROOT}

# The default command runs gunicorn WSGI server in impress's main module
CMD ["gunicorn", "-c", "/usr/local/etc/gunicorn/impress.py", "impress.wsgi:application"]
