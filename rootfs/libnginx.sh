#!/bin/bash
#
# Bitnami NGINX library

# shellcheck disable=SC1091

# Load Generic Libraries
. /libfile.sh
. /liblog.sh
. /libos.sh
. /libservice.sh
. /libvalidations.sh

# Functions

########################
# Check if NGINX is running
# Globals:
#   NGINX_TMPDIR
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_nginx_running() {
    local pid
    pid=$(get_pid_from_file "${NGINX_TMPDIR}/nginx.pid")

    if [[ -z "$pid" ]]; then
        false
    else
        is_service_running "$pid"
    fi
}

########################
# Stop NGINX
# Globals:
#   NGINX_TMPDIR
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_stop() {
    ! is_nginx_running && return
    debug "Stopping NGINX..."
    stop_service_using_pid "${NGINX_TMPDIR}/nginx.pid"
}

########################
# Load global variables used on NGINX configuration
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   Series of exports to be used as 'eval' arguments
#########################
nginx_env() {
    cat <<"EOF"
export NGINX_BASEDIR="/opt/bitnami/nginx"
export NGINX_VOLUME="/bitnami/nginx"
export NGINX_TMPDIR="${NGINX_BASEDIR}/tmp"
export NGINX_CONFDIR="${NGINX_BASEDIR}/conf"
export NGINX_LOGDIR="${NGINX_BASEDIR}/logs"
export NGINX_DAEMON_USER="${NGINX_DAEMON_USER:-daemon}"
export NGINX_DAEMON_GROUP="${NGINX_DAEMON_GROUP:-daemon}"
export PATH="${NGINX_BASEDIR}/sbin:$PATH"
export NGINX_ENABLE_CUSTOM_PORTS="${NGINX_ENABLE_CUSTOM_PORTS:-no}"
export NGINX_HTTPS_PORT_NUMBER="${NGINX_HTTPS_PORT_NUMBER:-}"
export NGINX_HTTP_PORT_NUMBER="${NGINX_HTTP_PORT_NUMBER:-}"
EOF
}

########################
# Check if NGINX configuration file is writable by current user
# Globals:
#   NGINX_CONFDIR
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_nginx_config_writable() {
    if [[ -w "${NGINX_CONFDIR}/nginx.conf" ]]; then
    true
    else
        warn "'nginx.conf' is not writable by current user. Skipping modifications..."
        false
    fi
}

########################
# Configure default HTTP port
# Globals:
#   NGINX_CONFDIR
# Arguments:
#    $1 - (optional) HTTP Port
# Returns:
#   None
#########################
nginx_config_http_port() {
    local http_port=${1:-8080}
    if is_nginx_config_writable; then
        local nginx_configuration
        debug "Configuring default HTTP port..."
        # TODO: find an appropriate NGINX parser to avoid 'sed calls'
        nginx_configuration="$(sed -E "s/(listen\s+)[0-9]{1,5};/\1${http_port};/g" "${NGINX_CONFDIR}/nginx.conf")"
        echo "$nginx_configuration" > "${NGINX_CONFDIR}/nginx.conf"
    fi
}

########################
# Validate settings in NGINX_* env vars
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_validate() {
    info "Validating settings in NGINX_* env vars..."

    local validate_port_args=()
    ! am_i_root && validate_port_args+=("-unprivileged")
    if [[ -n "${NGINX_HTTP_PORT_NUMBER:-}" ]]; then
        if ! err=$(validate_port "${validate_port_args[@]}" "${NGINX_HTTP_PORT_NUMBER:-}"); then
            error "An invalid port was specified in the environment variable NGINX_HTTP_PORT_NUMBER: $err"
            exit 1
        fi
    fi
}

########################
# Initialize NGINX
# Globals:
#   NGINX_*
# Arguments:
#   None
# Returns:
#   None
#########################
nginx_initialize() {
    info "Initializing NGINX..."

    # This fixes an issue where the trap would kill the entrypoint.sh, if a PID was left over from a previous run
    # Exec replaces the process without creating a new one, and when the container is restarted it may have the same PID
    rm -f "${NGINX_TMPDIR}/nginx.pid"

    # Persisted configuration files from old versions
    if [[ -f "$NGINX_VOLUME/conf/nginx.conf" ]]; then
        error "A 'nginx.conf' file was found inside '${NGINX_VOLUME}/conf'. This configuration is not supported anymore. Please mount the configuration file at '${NGINX_CONFDIR}/nginx.conf' instead."
        exit 1
    fi
    if ! is_dir_empty "$NGINX_VOLUME/conf/vhosts"; then
        error "Custom server blocks files were found inside '$NGINX_VOLUME/conf/vhosts'. This configuration is not supported anymore. Please mount your custom server blocks config files at '${NGINX_CONFDIR}/server_blocks' instead."
        exit 1
    fi

    debug "Updating 'nginx.conf' based on user configuration..."
    local nginx_user_configuration
    if am_i_root; then
        debug "Ensuring NGINX daemon user/group exists..."
        ensure_user_exists "$NGINX_DAEMON_USER" "$NGINX_DAEMON_GROUP"
        if [[ -n "${NGINX_DAEMON_USER:-}" ]]; then
            chown -R "${NGINX_DAEMON_USER:-}" "$NGINX_TMPDIR"
        fi
        nginx_user_configuration="$(sed -E "s/^(user\s+).*/\1 ${NGINX_DAEMON_USER:-} ${NGINX_DAEMON_GROUP:-};/g" "${NGINX_CONFDIR}/nginx.conf")"
        is_nginx_config_writable && echo "$nginx_user_configuration" > "${NGINX_CONFDIR}/nginx.conf"
    else
        # The "user" directive makes sense only if the master process runs with super-user privileges
        # TODO: find an appropriate NGINX parser to avoid 'sed calls'
        nginx_user_configuration="$(sed -E "s/(^user)/# \1/g" "${NGINX_CONFDIR}/nginx.conf")"
        is_nginx_config_writable && echo "$nginx_user_configuration" > "${NGINX_CONFDIR}/nginx.conf"
    fi
    if [[ -n "${NGINX_HTTP_PORT_NUMBER:-}" ]]; then
        nginx_config_http_port "${NGINX_HTTP_PORT_NUMBER}"
    fi
}
