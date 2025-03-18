# Django impress
# ---- base image to inherit from ----
FROM registry.redhat.io/ubi9/python-312 AS base

# ---- Back-end builder image ----
FROM base AS back-builder
USER 0
WORKDIR /builder
# Copy required python dependencies
COPY ./src/backend /builder
# Fix permissions for OpenShift
RUN chmod -R g+w /builder
USER 1001

# Install package to a writable location with proper permissions
RUN pip install --user .

# ---- mails ----
FROM registry.redhat.io/ubi9/nodejs-20 AS mail-builder
USER 0
# Create directories with proper permissions
RUN mkdir -p /mail/app && \
    chmod -R g+w /mail/app
    
COPY ./src/mail /mail/app
WORKDIR /mail/app

# Fix permissions for OpenShift
RUN chmod -R g+w /mail/app
USER 1001

# Install yarn and build
RUN npm install -g yarn && \
    mkdir -p /opt/app-root/src/.cache && \
    mkdir -p /mail/app/node_modules && \
    chmod -R g+w /opt/app-root/src/.cache && \
    chmod -R g+w /mail/app/node_modules && \
    HOME=/opt/app-root/src yarn install --frozen-lockfile && \
    HOME=/opt/app-root/src yarn build

# ---- static link collector ----
FROM base AS link-collector
ARG IMPRESS_STATIC_ROOT=/opt/app-root/static

# Install pango
USER 0
RUN dnf install -y pango
USER 1001

# Create the static directory with proper permissions
USER 0
RUN mkdir -p ${IMPRESS_STATIC_ROOT} && \
    chmod -R g+w ${IMPRESS_STATIC_ROOT}
USER 1001

# Copy impress application
COPY ./src/backend /app/
# Fix permissions
USER 0
RUN chmod -R g+w /app
USER 1001

# Copy installed python dependencies from back-builder
COPY --from=back-builder /opt/app-root/lib/python3.12/site-packages /opt/app-root/lib/python3.12/site-packages

WORKDIR /app

# collectstatic
RUN DJANGO_CONFIGURATION=Build \
    IMPRESS_STATIC_ROOT=${IMPRESS_STATIC_ROOT} \
    python manage.py collectstatic --noinput

# ---- Core application image ----
FROM base AS core
ENV PYTHONUNBUFFERED=1

# Install required system libs
USER 0
RUN dnf install -y \
  cairo \
  gettext \
  gdk-pixbuf2 \
  libffi-devel \
  pango \
  postgresql-client \
  shared-mime-info
USER 1001

# Get mime types
USER 0
RUN wget https://svn.apache.org/repos/asf/httpd/httpd/trunk/docs/conf/mime.types -O /etc/mime.types
USER 1001

# Create required directories with proper permissions
ARG IMPRESS_STATIC_ROOT=/opt/app-root/static
ARG IMPRESS_MEDIA_ROOT=/opt/app-root/media
USER 0
RUN mkdir -p ${IMPRESS_STATIC_ROOT} ${IMPRESS_MEDIA_ROOT} && \
    chmod -R g+w ${IMPRESS_STATIC_ROOT} ${IMPRESS_MEDIA_ROOT}
USER 1001

# Copy entrypoint
COPY ./docker/files/usr/local/bin/entrypoint /opt/app-root/bin/entrypoint
USER 0
RUN chmod +x /opt/app-root/bin/entrypoint
USER 1001

# Copy installed python dependencies from back-builder
COPY --from=back-builder /opt/app-root/lib/python3.12/site-packages /opt/app-root/lib/python3.12/site-packages

# Copy impress application
COPY ./src/backend /app/
# Fix permissions
USER 0
RUN chmod -R g+w /app
USER 1001

WORKDIR /app

# Generate compiled translation messages
RUN DJANGO_CONFIGURATION=Build \
    python manage.py compilemessages

# We use the provided entrypoint script
ENTRYPOINT [ "/opt/app-root/bin/entrypoint" ]

# ---- Development image ----
FROM core AS backend-development

# Install development dependencies
RUN pip install -e /app[dev]

# Target database host
ENV DB_HOST=postgresql \
    DB_PORT=5432 \
    IMPRESS_STATIC_ROOT=/opt/app-root/static \
    IMPRESS_MEDIA_ROOT=/opt/app-root/media

# Run django development server
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]

# ---- Production image ----
FROM core AS backend-production
ARG IMPRESS_STATIC_ROOT=/opt/app-root/static
ARG IMPRESS_MEDIA_ROOT=/opt/app-root/media

# Set environment variables
ENV IMPRESS_STATIC_ROOT=${IMPRESS_STATIC_ROOT} \
    IMPRESS_MEDIA_ROOT=${IMPRESS_MEDIA_ROOT}

# Gunicorn
RUN mkdir -p /opt/app-root/etc/gunicorn
COPY docker/files/usr/local/etc/gunicorn/impress.py /opt/app-root/etc/gunicorn/impress.py

# Copy statics
COPY --from=link-collector ${IMPRESS_STATIC_ROOT} ${IMPRESS_STATIC_ROOT}

# Copy impress mails
COPY --from=mail-builder /mail/backend/core/templates/mail /app/core/templates/mail
USER 0
RUN chmod -R g+w /app/core/templates/mail
USER 1001

# The default command runs gunicorn WSGI server in impress's main module
CMD ["gunicorn", "-c", "/opt/app-root/etc/gunicorn/impress.py", "impress.wsgi:application"]
