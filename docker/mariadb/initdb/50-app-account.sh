# Sourced (not executed) by the official image's entrypoint on first start,
# which provides docker_process_sql.  Creates the web application's account
# with the password from CAMPUS_APP_PASSWORD (compose.yaml / .env).
# docker/mariadb/Dockerfile installs it as 60-app-account.sh, after every SQL
# step including migrations 004-006.

bash /usr/local/share/campus/app_account.sh | docker_process_sql
