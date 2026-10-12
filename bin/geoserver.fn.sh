#!/usr/bin/env bash


# Retrieves GeoServer .war, either by fetching it from the cache or by
# downloading it. Ensure geoserver.war is present in the build dir
#
# Usage: get_geoserver <build_dir> <cache_dir> <version>
#
get_geoserver() {
    local build_dir="${1}"
    local cache_dir="${2}"
    local version="${3}"

    local archive_name="geoserver-${version}-war.zip"
    local url="https://sourceforge.net/projects/geoserver/files/GeoServer/${version}/${archive_name}"
    local zip_cache_file="${cache_dir}/geoserver-${version}.zip"

    # Validate cached file before reusing it
    if [ -f "${zip_cache_file}" ]; then
        if ! unzip -tq "${zip_cache_file}" > /dev/null 2>&1; then
            echo "!! Cached GeoServer ZIP is corrupted, re-downloading" >&2
            rm -f "${zip_cache_file}"
        fi
    fi

    if [ ! -f "${zip_cache_file}" ] ; then
        echo "---> Downloading GeoServer ${version}"
        if ! curl --retry 3 --fail --show-error --location "${url}" \
            --output "${zip_cache_file}"; then
            echo "!! Failed to download GeoServer ${version} from ${url}" >&2
            rm -f "${zip_cache_file}"
            exit 1
        fi

        # Verify the downloaded file is a valid ZIP
        if ! unzip -tq "${zip_cache_file}" > /dev/null 2>&1; then
            echo "!! Downloaded GeoServer archive is not a valid ZIP file" >&2
            echo "!! This may be caused by a SourceForge issue (HTML error page, incomplete download)" >&2
            rm -f "${zip_cache_file}"
            exit 1
        fi
    else
        echo "---> Retrieving GeoServer ${version} from cache"
    fi

    # Either we got geoserver zip from the cache or from the project page
    unzip -qq -o "${zip_cache_file}" -d "${build_dir}/geoserver-${version}"

    # Verify the WAR file was extracted
    if [ ! -f "${build_dir}/geoserver-${version}/geoserver.war" ]; then
        echo "!! GeoServer WAR file not found after extraction" >&2
        echo "!! The ZIP archive may not contain the expected geoserver.war file" >&2
        exit 1
    fi

    # Ensure we have a working link to current war version in $build_dir/geoserver.war
    pushd "${build_dir}" > /dev/null \
        && ln -sfn "geoserver-${version}/geoserver.war" "geoserver.war" \
        && popd > /dev/null
}


# Starts GeoServer locally so we can inject the configuration.
# Returns the pid of the process.
#
# Usage: run_geoserver <build_dir> <port>
#
run_geoserver() {
    local build_dir
    local port

    build_dir="${1}"
    port="${2}"

    # Starts the webserver in background (will be killed later)
    # Logs are kept in out.log and dumped on failure for debugging
    java ${JAVA_OPTS:-} -jar "${build_dir}/webapp-runner.jar" \
        --port "${port}" \
        "${build_dir}/geoserver.war" \
        > out.log 2>&1 &
}


# Stops the process corresponding to the given PID.
#
# Usage: stop_geoserver <pid>
#
stop_geoserver() {
    local pid
    local waited

    pid="${1}"
    waited=0

    set +e

    kill -SIGTERM "${pid}"

    while [ ${waited} -lt 180 ]
    do
        sleep 1

        kill -0 "${pid}" > /dev/null 2>&1 \
            || break

        ((waited++))
    done

    kill -0 "${pid}" > /dev/null 2>&1 \
        && {
            kill -SIGKILL "${pid}"
            echo "!! Temporary GeoServer was not responding and has been killed."
            echo "!! Stopping build as this may have introduced data corruption."
            exit 1
        }

    set -e
}


# Installs Java and webapp_runner
#
# Usage: install_java_webapp_runner <build_dir> <cache_dir> <env_dir>
#
install_java_webapp_runner() {
    local build_dir
    local cache_dir
    local env_dir

    local java_war_buildpack_url
    local java_war_buildpack_dir

    build_dir="${1}"
    cache_dir="${2}"
    env_dir="${3}"

    java_war_buildpack_url="https://github.com/Scalingo/java-war-buildpack.git"
    java_war_buildpack_dir="$( mktemp java_war_buildpack_XXXX )"

    # We only need a random name, let's remove the file:
    rm "${java_war_buildpack_dir}"

    # Clone the java-war-buildpack:
    git clone --depth=1 "${java_war_buildpack_url}" "${java_war_buildpack_dir}"

    # And call it:
    "${java_war_buildpack_dir}/bin/compile" \
        "${build_dir}" "${cache_dir}" "${env_dir}"

    # The java-war-buildpack leaves an `export` file in `$( pwd )`.
    # Let's source it:
    if [ -e "./export" ]; then
        source "./export"
    fi

    # Cleanup:
    rm -Rf "${java_war_buildpack_dir}"
}


# Prints out some environment variables.
#
# Usage: print_environment
#
print_environment() {
    echo -e "     GEOSERVER_VERSION: ${geoserver_version}"
    echo -e "     GEOSERVER_CONFIG_SCRIPT: ${geoserver_config_script}"
    echo -e "     GEOSERVER_DATA_DIR: ${geoserver_data_dir}"
    echo -e "     JAVA_VERSION: ${JAVA_VERSION}"
    echo -e "     JAVA_WEBAPP_RUNNER_VERSION: ${JAVA_WEBAPP_RUNNER_VERSION}"
}


# Checks whether all required environment variables are set or not.
#
# Usage: check_environment
#
check_environment() {
    local mandatory
    local mandatory_is_ok

    mandatory=(
        GEOSERVER_ADMIN_PASSWORD
        GEOSERVER_WORKSPACE_NAME
        GEOSERVER_DATASTORE_NAME
    )

    mandatory_is_ok=0

    for m in "${mandatory[@]}"
    do
        if [ -z "${!m}" ]
        then
            echo "!! Setting the ${m} environment variable is mandatory." >&2
            echo "!! Please set it and relaunch your deployment." >&2
            mandatory_is_ok=1
        fi
    done

    if [ -z "${SCALINGO_POSTGRESQL_URL}" ]
    then
        echo "!! This buildpack requires a PostgreSQL database addon." >&2
        mandatory_is_ok=1
    fi

    if [ ${mandatory_is_ok} -ne 0 ]
    then
        exit 1
    fi
}


# Split the DB connexion string into multiple environment variables
# so we can use them in the templates
#
# Usage: export_db_conn
#
export_db_conn() {
    DB_HOST="$( echo "${SCALINGO_POSTGRESQL_URL}" \
        | cut -d "@" -f2 | cut -d ":" -f1 )"

    DB_USER="$( echo "${SCALINGO_POSTGRESQL_URL}" \
        | cut -d "/" -f3 | cut -d ":" -f1 )"

    DB_PORT="$( echo "${SCALINGO_POSTGRESQL_URL}" \
        | cut -d ":" -f4 | cut -d "/" -f1 )"

    DB_PASS="$( echo "${SCALINGO_POSTGRESQL_URL}" \
        | cut -d "@" -f1 | cut -d ":" -f3 )"

    DB_NAME="$( echo "${SCALINGO_POSTGRESQL_URL}" \
        | cut -d "?" -f1 | cut -d "/" -f4 )"

    export DB_HOST
    export DB_USER
    export DB_PORT
    export DB_PASS
    export DB_NAME
}


# Interpolates variables present in the given template.
#
# Usage: do_template <template_file>
#
do_template() {
    local src
    local dst

    src="${1}"
    # dst is the same as src, exept we remove the '.erb' suffix:
    dst="${src%.erb}"

    # Process the template:
    erb "${src}" > "${dst}"
}


# Enforces the disk space dedicated to GeoWebCache.
#
# Usage: enforce_geowebcache_diskquota <buildpack_dir>
#
# !! Don't use an API call to do this, it won't persist during the
# BUILD --> RUN transition.
#
enforce_geowebcache_diskquota() {
    local buildpack_dir

    buildpack_dir="${1}"

    mkdir -p "${GEOSERVER_DATA_DIR}/gwc"

    cp "${buildpack_dir}/config/geowebcache-diskquota.xml" \
        "${GEOSERVER_DATA_DIR}/gwc/"
}


# Enforces logging to stdout.
#
# Usage: enforce_logging_to_stdout <buildpack_dir>
#
enforce_logging_to_stdout() {
    local buildpack_dir
    local url
    local user
    local pass

    buildpack_dir="${1}"
    url="${2}"
    user="${3}"
    pass="${4}"

    mkdir -p "${GEOSERVER_DATA_DIR}/logs"

    cp "${buildpack_dir}/config/SCALINGO_LOGGING.xml" \
        "${GEOSERVER_DATA_DIR}/logs/"

    # !! For some reason, using '--fail' with this one makes curl crash.
    # Redirecting outputs to /dev/null instead.
    curl -4 --silent --show-error --request PUT \
        "${url}/rest/logging" \
        --user "${user}":"${pass}" \
        --header "Content-Type: application/json" \
        --data "@${buildpack_dir}/config/logging.json" \
        > /dev/null 2>&1
}


# Removes masterpw.info file.
#
# Usage: remove_masterpw
#
remove_masterpw() {
    rm -f "${GEOSERVER_DATA_DIR}/security/masterpw.info"
}


# Sets admin user account password.
#
# Usage: set_admin_password <buildpack_dir> <url> <user> <pass>
#
set_admin_password() {
    local buildpack_dir
    local url
    local user
    local pass

    buildpack_dir="${1}"
    url="${2}"
    user="${3}"
    pass="${4}"

    curl -4 --silent --fail --show-error --request PUT \
        "${url}/rest/security/self/password" \
        --user "${user}":"${pass}" \
        --header "Content-Type: application/json" \
        --data "@${buildpack_dir}/config/adminpw.json"
}


# Creates the GEOSERVER_WORKSPACE_NAME workspace.
#
# Usage: create_workspace <buildpack_dir> <url> <user> <pass>
#
create_workspace() {
    local buildpack_dir
    local url
    local user
    local pass

    buildpack_dir="${1}"
    url="${2}"
    user="${3}"
    pass="${4}"

    # Make sure the workspace doesn't exist:
    # (also make sure this won't fail when the workspace does not exist yet)

    curl -4 --silent --fail --request DELETE \
        "${url}/rest/workspaces/${GEOSERVER_WORKSPACE_NAME}?recurse=true" \
        --user "${user}":"${pass}" \
        || true

    curl -4 --silent --fail --show-error --request POST \
        "${url}/rest/workspaces" \
        --user "${user}":"${pass}" \
        --header "Content-Type: application/json" \
        --data "@${buildpack_dir}/config/workspace.json"
}


# Creates the GEOSERVER_DATASTORE_NAME datastore in the
# GEOSERVER_WORKSPACE_NAME workspace.
#
# Usage: create_datastore <buildpack_dir> <url> <user> <pass>
#
create_datastore() {
    local buildpack_dir
    local url
    local user
    local pass

    buildpack_dir="${1}"
    url="${2}"
    user="${3}"
    pass="${4}"

    curl -4 --silent --fail --show-error --request POST \
        "${url}/rest/workspaces/${GEOSERVER_WORKSPACE_NAME}/datastores" \
        --user "${user}":"${pass}" \
        --header "Content-Type: application/json" \
        --data "@${buildpack_dir}/config/datastore.json"
}

readonly -f get_geoserver
readonly -f run_geoserver
readonly -f stop_geoserver
readonly -f install_java_webapp_runner
readonly -f check_environment
readonly -f print_environment
readonly -f export_db_conn
readonly -f do_template
readonly -f enforce_geowebcache_diskquota
readonly -f enforce_logging_to_stdout
readonly -f remove_masterpw
readonly -f set_admin_password
readonly -f create_workspace
readonly -f create_datastore
