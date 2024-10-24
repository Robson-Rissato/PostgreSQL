#!/usr/bin/env bash
set -Eeuo pipefail

#
# Este script é destinado a três principais casos de uso:
#
#  1. (mais importante) como um exemplo de como usar "docker-entrypoint.sh" para estender/reutilizar o comportamento de inicialização
#
#  2. ("docker-ensure-initdb.sh") como um "init container" no Kubernetes para garantir que o diretório de banco de dados fornecido esteja inicializado; 
#  veja também "startup probes" para uma solução alternativa (nenhuma ação se o banco de dados já estiver inicializado)
#
#  3. ("docker-enforce-initdb.sh") como parte do CI para garantir que o banco de dados esteja totalmente inicializado antes do uso
#       (erro se o banco de dados já estiver inicializado)
#

source /usr/local/bin/docker-entrypoint.sh

# os argumentos para este script são assumidos como argumentos para o servidor "postgres" (mesmo que em "docker-entrypoint.sh"), 
# e a maioria das funções de "docker-entrypoint.sh" assume "postgres" como o primeiro argumento (veja "_main" lá)
if [ "$#" -eq 0 ] || [ "$1" != 'postgres' ]; then
	set -- postgres "$@"
fi

# veja também "_main" em "docker-entrypoint.sh"

docker_setup_env
# configurar diretórios de dados e permissões (quando executado como root)
docker_create_db_directories
if [ "$(id -u)" = '0' ]; then
	# então reinicia o script como usuário postgres
	exec gosu postgres "$BASH_SOURCE" "$@"
fi

# executar inicialização apenas em um diretório de dados vazio
if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
	docker_verify_minimum_env

	# verificar permissões do diretório para reduzir a probabilidade de banco de dados parcialmente inicializado
	ls /docker-entrypoint-initdb.d/ > /dev/null

	docker_init_database_dir
	pg_setup_hba_conf "$@"

	# PGPASSWORD é necessário para psql quando a autenticação é requerida para conexões 'local' via pg_hba.conf e é inofensivo de outra forma
	# por exemplo, quando '--auth=md5' ou '--auth-local=md5' é usado em POSTGRES_INITDB_ARGS
	export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
	docker_temp_server_start "$@"

	docker_setup_db
	docker_process_init_files /docker-entrypoint-initdb.d/*

	docker_temp_server_stop
	unset PGPASSWORD
else
	self="$(basename "$0")"
	case "$self" in
		docker-ensure-initdb.sh)
			echo >&2 "$self: note: database already initialized in '$PGDATA'!"
			exit 0
			;;

		docker-enforce-initdb.sh)
			echo >&2 "$self: error: (unexpected) database found in '$PGDATA'!"
			exit 1
			;;

		*)
			echo >&2 "$self: error: unknown file name: $self"
			exit 99
			;;
	esac
fi