#!/usr/bin/env bash
set -Eeo pipefail
# TODO trocar para -Eeuo pipefail acima (após lidar com todas as variáveis potencialmente não definidas)

# uso: file_env VAR [DEFAULT]
#    ex: file_env 'XYZ_DB_PASSWORD' 'example'
#    (permitirá que "$XYZ_DB_PASSWORD_FILE" preencha o valor de
#    "$XYZ_DB_PASSWORD" a partir de um arquivo, especialmente para o recurso de segredos do Docker)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        printf >&2 'error: both %s and %s are set (but are exclusive)\n' "$var" "$fileVar"
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(< "${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# verifica se este arquivo está sendo executado ou incluído de outro script
_is_sourced() {
    # https://unix.stackexchange.com/a/215279
    [ "${#FUNCNAME[@]}" -ge 2 ] \
        && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
        && [ "${FUNCNAME[1]}" = 'source' ]
}

# usado para criar diretórios iniciais do postgres e, se executado como root, garantir propriedade ao usuário "postgres"
docker_create_db_directories() {
    local user; user="$(id -u)"

    mkdir -p "$PGDATA"
    # ignora falhas, pois há casos em que não podemos usar chmod (e o PostgreSQL pode falhar mais tarde de qualquer forma - ele é exigente quanto às permissões deste diretório)
    chmod 00700 "$PGDATA" || :

    # ignora falhas, pois funcionará ao usar o diretório fornecido pela imagem; 
    mkdir -p /var/run/postgresql || :
    chmod 03775 /var/run/postgresql || :

    # Cria o diretório de log de transação antes de executar o initdb para que o diretório seja de propriedade do usuário correto
    if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
        mkdir -p "$POSTGRES_INITDB_WALDIR"
        if [ "$user" = '0' ]; then
            find "$POSTGRES_INITDB_WALDIR" \! -user postgres -exec chown postgres '{}' +
        fi
        chmod 700 "$POSTGRES_INITDB_WALDIR"
    fi

    # permite que o contêiner seja iniciado com `--user`
    if [ "$user" = '0' ]; then
        find "$PGDATA" \! -user postgres -exec chown postgres '{}' +
        find /var/run/postgresql \! -user postgres -exec chown postgres '{}' +
    fi
}

# inicializa o diretório PGDATA vazio com um novo banco de dados via 'initdb'
# argumentos para `initdb` podem ser passados via POSTGRES_INITDB_ARGS ou como argumentos para esta função
# `initdb` cria automaticamente os dbnames "postgres", "template0" e "template1"
# é aqui também que o usuário do banco de dados é criado, especificado pela variável de ambiente `POSTGRES_USER`
docker_init_database_dir() {
    # "initdb" é particular sobre o usuário atual existir em "/etc/passwd", então usamos "nss_wrapper" para simular isso se necessário
    local uid; uid="$(id -u)"
    if ! getent passwd "$uid" &> /dev/null; then
        # veja se podemos encontrar um "libnss_wrapper.so" adequado (https://salsa.debian.org/sssd-team/nss-wrapper/-/commit/b9925a653a54e24d09d9b498a2d913729f7abb15)
        local wrapper
        for wrapper in {/usr,}/lib{/*,}/libnss_wrapper.so; do
            if [ -s "$wrapper" ]; then
                NSS_WRAPPER_PASSWD="$(mktemp)"
                NSS_WRAPPER_GROUP="$(mktemp)"
                export LD_PRELOAD="$wrapper" NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
                local gid; gid="$(id -g)"
                printf 'postgres:x:%s:%s:PostgreSQL:%s:/bin/false\n' "$uid" "$gid" "$PGDATA" > "$NSS_WRAPPER_PASSWD"
                printf 'postgres:x:%s:\n' "$gid" > "$NSS_WRAPPER_GROUP"
                break
            fi
        done
    fi

    if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
        set -- --waldir "$POSTGRES_INITDB_WALDIR" "$@"
    fi

    # --pwfile se recusa a lidar com um arquivo propriamente vazio (daí o "\n")
    eval 'initdb --username="$POSTGRES_USER" --pwfile=<(printf "%s\n" "$POSTGRES_PASSWORD") '"$POSTGRES_INITDB_ARGS"' "$@"'

    # limpa/desconfigura bits do "nss_wrapper"
    if [[ "${LD_PRELOAD:-}" == */libnss_wrapper.so ]]; then
        rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP"
        unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
    fi
}

# imprime um grande aviso se POSTGRES_PASSWORD for longa
# erro se POSTGRES_PASSWORD estiver vazia e POSTGRES_HOST_AUTH_METHOD não for 'trust'
# imprime um grande aviso se POSTGRES_HOST_AUTH_METHOD estiver definido como 'trust'
# assume que o banco de dados não está configurado, ou seja: [ -z "$DATABASE_ALREADY_EXISTS" ]
docker_verify_minimum_env() {
    case "${PG_MAJOR:-}" in
        12 | 13) 
            # verifica a senha primeiro para que possamos emitir o aviso antes que o postgres
            # a bagunce
            if [ "${#POSTGRES_PASSWORD}" -ge 100 ]; then
                cat >&2 <<-'EOWARN'

                    AVISO: A POSTGRES_PASSWORD fornecida tem 100+ caracteres.

                      Isso não funcionará se usado via PGPASSWORD com "psql".

                      https://www.postgresql.org/message-id/flat/E1Rqxp2-0004Qt-PL%40wrigleys.postgresql.org)                      

                EOWARN
            fi
            ;;
    esac
    if [ -z "$POSTGRES_PASSWORD" ] && [ 'trust' != "$POSTGRES_HOST_AUTH_METHOD" ]; then
        # A opção - suprime tabulações iniciais mas *não* espaços. :)
        cat >&2 <<-'EOE'
            Erro: Banco de dados não inicializado e senha do superusuário não especificada.
                   Você deve especificar POSTGRES_PASSWORD com um valor não vazio para o
                   superusuário. Por exemplo, "-e POSTGRES_PASSWORD=senha" no "docker run".

                   Você também pode usar "POSTGRES_HOST_AUTH_METHOD=trust" para permitir todas
                   as conexões sem uma senha. Isso *não* é recomendado.

                   Veja a documentação do PostgreSQL sobre "trust":
                   https://www.postgresql.org/docs/current/auth-trust.html
        EOE
        exit 1
    fi
    if [ 'trust' = "$POSTGRES_HOST_AUTH_METHOD" ]; then
        cat >&2 <<-'EOWARN'
            ********************************************************************************
            AVISO: POSTGRES_HOST_AUTH_METHOD foi definido como "trust". Isso permitirá
                     que qualquer pessoa com acesso à porta do Postgres acesse seu banco de dados sem
                     uma senha, mesmo se POSTGRES_PASSWORD estiver definido. Veja a documentação do
                     PostgreSQL sobre "trust":
                     https://www.postgresql.org/docs/current/auth-trust.html
                     Na configuração padrão do Docker, isso é efetivamente qualquer outro
                     contêiner no mesmo sistema.

                     Não é recomendado usar POSTGRES_HOST_AUTH_METHOD=trust. Substitua
                     por "-e POSTGRES_PASSWORD=senha" em vez disso para definir uma senha em
                     "docker run".
            ********************************************************************************
        EOWARN
    fi
}

# uso: docker_process_init_files [arquivo [arquivo [...]]]
#    ex: docker_process_init_files /always-initdb.d/*
# processa arquivos inicializadores, com base nas extensões de arquivo e permissões
docker_process_init_files() {
    # psql aqui para compatibilidade retroativa "${psql[@]}"
    psql=( docker_process_sql )

    printf '\n'
    local f
    for f; do
        case "$f" in
            *.sh)
                if [ -x "$f" ]; then
                    printf '%s: executando %s\n' "$0" "$f"
                    "$f"
                else
                    printf '%s: incluindo %s\n' "$0" "$f"
                    . "$f"
                fi
                ;;
            *.sql)     printf '%s: executando %s\n' "$0" "$f"; docker_process_sql -f "$f"; printf '\n' ;;
            *.sql.gz)  printf '%s: executando %s\n' "$0" "$f"; gunzip -c "$f" | docker_process_sql; printf '\n' ;;
            *.sql.xz)  printf '%s: executando %s\n' "$0" "$f"; xzcat "$f" | docker_process_sql; printf '\n' ;;
            *.sql.zst) printf '%s: executando %s\n' "$0" "$f"; zstd -dc "$f" | docker_process_sql; printf '\n' ;;
            *)         printf '%s: ignorando %s\n' "$0" "$f" ;;
        esac
        printf '\n'
    done
}

# Executa script SQL, passado via stdin (ou flag -f do psql)
# uso: docker_process_sql [psql-cli-args]
#    ex: docker_process_sql --dbname=mydb <<<'INSERT ...'
#    ex: docker_process_sql -f my-file.sql
#    ex: docker_process_sql <my-file.sql
docker_process_sql() {
    local query_runner=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password --no-psqlrc )
    if [ -n "$POSTGRES_DB" ]; then
        query_runner+=( --dbname "$POSTGRES_DB" )
    fi

    PGHOST= PGHOSTADDR= "${query_runner[@]}" "$@"
}

# cria banco de dados inicial
# usa variáveis de ambiente para entrada: POSTGRES_DB
docker_setup_db() {
    local dbAlreadyExists
    dbAlreadyExists="$(
        POSTGRES_DB= docker_process_sql --dbname postgres --set db="$POSTGRES_DB" --tuples-only <<-'EOSQL'
            SELECT 1 FROM pg_database WHERE datname = :'db' ;
        EOSQL
    )"
    if [ -z "$dbAlreadyExists" ]; then
        POSTGRES_DB= docker_process_sql --dbname postgres --set db="$POSTGRES_DB" <<-'EOSQL'
            CREATE DATABASE :"db" ;
        EOSQL
        printf '\n'
    fi
}

# Carrega várias configurações que são usadas em outras partes do script
# Isto deve ser chamado antes de qualquer outra função
docker_setup_env() {
    file_env 'POSTGRES_PASSWORD'

    file_env 'POSTGRES_USER' 'postgres'
    file_env 'POSTGRES_DB' "$POSTGRES_USER"
    file_env 'POSTGRES_INITDB_ARGS'
    : "${POSTGRES_HOST_AUTH_METHOD:=}"

    declare -g DATABASE_ALREADY_EXISTS
    : "${DATABASE_ALREADY_EXISTS:=}"
    # procura especificamente por PG_VERSION, como é esperado no diretório do BD
    if [ -s "$PGDATA/PG_VERSION" ]; then
        DATABASE_ALREADY_EXISTS='true'
    fi
}

# anexa POSTGRES_HOST_AUTH_METHOD ao pg_hba.conf para conexões "host"
# todos os argumentos serão passados como argumentos para `postgres` para obter o valor de 'password_encryption'
pg_setup_hba_conf() {
    # método de autenticação padrão é md5 em versões antes da 14
    # https://www.postgresql.org/about/news/postgresql-14-released-2318/
    if [ "$1" = 'postgres' ]; then
        shift
    fi
    local auth
    # verifica a criptografia padrão/configurada e usa isso como método de autenticação
    auth="$(postgres -C password_encryption "$@")"
    : "${POSTGRES_HOST_AUTH_METHOD:=$auth}"
    {
        printf '\n'
        if [ 'trust' = "$POSTGRES_HOST_AUTH_METHOD" ]; then
            printf '# aviso: trust está habilitado para todas as conexões\n'
            printf '# veja https://www.postgresql.org/docs/12/auth-trust.html\n'
        fi
        printf 'host all all all %s\n' "$POSTGRES_HOST_AUTH_METHOD"
    } >> "$PGDATA/pg_hba.conf"
}

# inicia servidor PostgreSQL somente socket para configurar ou executar scripts
# todos os argumentos serão passados como argumentos para `postgres` (via pg_ctl)
docker_temp_server_start() {
    if [ "$1" = 'postgres' ]; then
        shift
    fi

    # início interno do servidor para permitir configuração usando o cliente psql
    # não escuta em TCP/IP externo e espera até que o início seja concluído
    set -- "$@" -c listen_addresses='' -p "${PGPORT:-5432}"

    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    pg_ctl -D "$PGDATA" \
        -o "$(printf '%q ' "$@")" \
        -w start
}

# para o servidor PostgreSQL após terminar de configurar o usuário e executar scripts
docker_temp_server_stop() {
    PGUSER="${PGUSER:-postgres}" \
    pg_ctl -D "$PGDATA" -m fast -w stop
}

# verifica argumentos para uma opção que faria o postgres parar
# retorna verdadeiro se houver um
_pg_want_help() {
    local arg
    for arg; do
        case "$arg" in
            # postgres --help | grep 'then exit'
            # deixando de fora -C de propósito, pois sempre falha e não é útil:
            # postgres: não pôde acessar o arquivo de configuração do servidor "/var/lib/postgresql/data/postgresql.conf": Arquivo ou diretório não encontrado
            -'?'|--help|--describe-config|-V|--version)
                return 0
                ;;
        esac
    done
    return 1
}

_main() {
    # se o primeiro argumento parecer uma flag, assumimos que queremos executar o servidor postgres
    if [ "${1:0:1}" = '-' ]; then
        set -- postgres "$@"
    fi

    if [ "$1" = 'postgres' ] && ! _pg_want_help "$@"; then
        docker_setup_env
        # configura diretórios de dados e permissões (quando executado como root)
        docker_create_db_directories
        if [ "$(id -u)" = '0' ]; then
            # então reinicia o script como usuário postgres
            exec gosu postgres "$BASH_SOURCE" "$@"
        fi

        # executar inicialização apenas em um diretório de dados vazio
        if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
            docker_verify_minimum_env

            # verifica permissões do diretório para reduzir a probabilidade de banco de dados parcialmente inicializado
            ls /docker-entrypoint-initdb.d/ > /dev/null

            docker_init_database_dir
            pg_setup_hba_conf "$@"

            # PGPASSWORD é necessário para psql quando a autenticação é necessária para conexões 'local' via pg_hba.conf e é inofensivo de outra forma
            # por exemplo, quando '--auth=md5' ou '--auth-local=md5' é usado em POSTGRES_INITDB_ARGS
            export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
            docker_temp_server_start "$@"

            docker_setup_db
            docker_process_init_files /docker-entrypoint-initdb.d/*

            docker_temp_server_stop
            unset PGPASSWORD

            cat <<-'EOM'

                Processo de inicialização do PostgreSQL completo; pronto para iniciar.

            EOM
        else
            cat <<-'EOM'

                O diretório do banco de dados PostgreSQL parece conter um banco de dados; pulando inicialização

            EOM
        fi
    fi

    exec "$@"
}

if ! _is_sourced; then
    _main "$@"
fi