FROM debian:bookworm-slim

# definir explicitamente os IDs de usuário/grupo
RUN set -eux; \
    groupadd -r postgres --gid=999; \
    useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
    # também cria o diretório home do usuário postgres com as permissões apropriadas
    install --verbose --directory --owner postgres --group postgres --mode 1777 /var/lib/postgresql

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    gnupg \
    # (se "less" estiver disponível, ele é usado como pager padrão para psql, e adiciona apenas ~1.5MiB ao tamanho da nossa imagem)
    less \
    ; \
    rm -rf /var/lib/apt/lists/*

# obter gosu para facilitar a troca do usuário root
ENV GOSU_VERSION 1.17
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget; \
    rm -rf /var/lib/apt/lists/*; \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
    apt-mark auto '.*' > /dev/null; \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    chmod +x /usr/local/bin/gosu; \
    gosu --version; \
    gosu nobody true

# criar o locale "en_US.UTF-8" para que o postgres seja habilitado com utf-8 por padrão
RUN set -eux; \
    if [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \
    # se este arquivo existir, provavelmente estamos em "debian:xxx-slim", e os locales estão sendo excluídos, então precisamos remover essa exclusão (já que precisamos de locales)
    grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
    sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \
    ! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
    fi; \
    apt-get update; apt-get install -y --no-install-recommends locales; rm -rf /var/lib/apt/lists/*; \
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen; \
    locale-gen; \
    locale -a | grep 'en_US.utf8'
ENV LANG en_US.utf8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    libnss-wrapper \
    xz-utils \
    zstd \
    ; \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /docker-entrypoint-initdb.d

RUN set -ex; \
    key='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8'; \
    export GNUPGHOME="$(mktemp -d)"; \
    mkdir -p /usr/local/share/keyrings/; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
    gpg --batch --export --armor "$key" > /usr/local/share/keyrings/postgres.gpg.asc; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME"

ENV PG_MAJOR 17
ENV PATH $PATH:/usr/lib/postgresql/$PG_MAJOR/bin

ENV PG_VERSION 17.0-1.pgdg120+1

RUN set -ex; \
    \
    # veja a nota abaixo sobre arquivos "*.pyc"
    export PYTHONDONTWRITEBYTECODE=1; \
    \
    dpkgArch="$(dpkg --print-architecture)"; \
    aptRepo="[ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg main $PG_MAJOR"; \
    case "$dpkgArch" in \
    amd64 | arm64 | ppc64el | s390x) \
    # arquiteturas oficialmente construídas pelo upstream
    echo "deb $aptRepo" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    ;; \
    *) \
    # estamos em uma arquitetura que o upstream não constrói oficialmente
    # vamos construir binários a partir dos pacotes fonte publicados por eles
    echo "deb-src $aptRepo" > /etc/apt/sources.list.d/pgdg.list; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    tempDir="$(mktemp -d)"; \
    cd "$tempDir"; \
    \
    # criar um repositório APT local temporário para instalar (para que a resolução de dependências possa ser tratada pelo APT, como deveria ser)
    apt-get update; \
    apt-get install -y --no-install-recommends dpkg-dev; \
    echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list; \
    _update_repo() { \
    dpkg-scanpackages . > Packages; \
    # contornar o seguinte problema do APT usando "Acquire::GzipIndexes=false" (substituindo "/etc/apt/apt.conf.d/docker-gzip-indexes")
    #   Não foi possível abrir o arquivo /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permissão negada)
    #   ...
    #   E: Falha ao buscar store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Não foi possível abrir o arquivo /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permissão negada)
    apt-get -o Acquire::GzipIndexes=false update; \
    }; \
    _update_repo; \
    \
    # construir arquivos .deb a partir dos pacotes fonte publicados pelo upstream (que são verificados pelo apt-get)
    nproc="$(nproc)"; \
    export DEB_BUILD_OPTIONS="nocheck parallel=$nproc"; \
    # temos que construir postgresql-common primeiro porque postgresql-$PG_MAJOR compartilha a lógica de "debian/rules" com ele: https://salsa.debian.org/postgresql/postgresql/-/commit/99f44476e258cae6bf9e919219fa2c5414fa2876
    # (e ele "Depende: pgdg-keyring")
    apt-get build-dep -y postgresql-common pgdg-keyring; \
    apt-get source --compile postgresql-common pgdg-keyring; \
    _update_repo; \
    apt-get build-dep -y "postgresql-$PG_MAJOR=$PG_VERSION"; \
    apt-get source --compile "postgresql-$PG_MAJOR=$PG_VERSION"; \
    \
    # não removemos as listas APT aqui porque elas são rebaixadas e removidas posteriormente
    \
    # redefinir a lista "manual" do apt-mark para que "purge --auto-remove" remova todas as dependências de compilação
    # (o que é feito depois de instalarmos os pacotes construídos, para que não precisemos baixar novamente quaisquer dependências sobrepostas)
    apt-mark showmanual | xargs apt-mark auto > /dev/null; \
    apt-mark manual $savedAptMark; \
    \
    ls -lAFh; \
    _update_repo; \
    grep '^Package: ' Packages; \
    cd /; \
    ;; \
    esac; \
    \
    apt-get install -y --no-install-recommends postgresql-common; \
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
    apt-get install -y --no-install-recommends \
    "postgresql-$PG_MAJOR=$PG_VERSION" \
    ; \
    \
    rm -rf /var/lib/apt/lists/*; \
    \
    if [ -n "$tempDir" ]; then \
    # se tivermos restos da compilação, vamos purgá-los (incluindo dependências de compilação extras e desnecessárias)
    apt-get purge -y --auto-remove; \
    rm -rf "$tempDir" /etc/apt/sources.list.d/temp.list; \
    fi; \
    \
    # algumas das etapas acima geram muitos arquivos "*.pyc" (e definir "PYTHONDONTWRITEBYTECODE" previamente não se propaga adequadamente por algum motivo), então os limpamos manualmente (desde que não sejam pertencentes a um pacote)
    find /usr -name '*.pyc' -type f -exec bash -c 'for pyc; do dpkg -S "$pyc" &> /dev/null || rm -vf "$pyc"; done' -- '{}' +; \
    \
    postgres --version

# tornar a configuração de exemplo mais fácil de modificar (e "correta por padrão")
RUN set -eux; \
    dpkg-divert --add --rename --divert "/usr/share/postgresql/postgresql.conf.sample.dpkg" "/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample"; \
    cp -v /usr/share/postgresql/postgresql.conf.sample.dpkg /usr/share/postgresql/postgresql.conf.sample; \
    ln -sv ../postgresql.conf.sample "/usr/share/postgresql/$PG_MAJOR/"; \
    sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/share/postgresql/postgresql.conf.sample; \
    grep -F "listen_addresses = '*'" /usr/share/postgresql/postgresql.conf.sample

RUN install --verbose --directory --owner postgres --group postgres --mode 3777 /var/run/postgresql

ENV PGDATA /var/lib/postgresql/data
# este 1777 será substituído por 0700 em tempo de execução (permite valores semi-arbitrários de "--user")
RUN install --verbose --directory --owner postgres --group postgres --mode 1777 "$PGDATA"
VOLUME /var/lib/postgresql/data
# --- Início das configurações adicionadas ---

# Definir a variável de ambiente do fuso horário
ENV TZ=America/Sao_Paulo

# Instalar pacotes adicionais e configurar o fuso horário
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    tzdata \
    postgresql-17-postgis-3 \
    postgresql-17-postgis-3-scripts \
    mc \
    net-tools \
    ; \
    ln -sf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo "$TZ" > /etc/timezone; \
    dpkg-reconfigure -f noninteractive tzdata; \
    rm -rf /var/lib/apt/lists/*

# --- Fim das configurações adicionadas ---

COPY docker-entrypoint.sh docker-ensure-initdb.sh /usr/local/bin/
RUN ln -sT docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh
ENTRYPOINT ["docker-entrypoint.sh"]

# Definimos o STOPSIGNAL padrão para SIGINT, que corresponde ao que o PostgreSQL
# chama de "Modo de Desligamento Rápido", onde novas conexões são desabilitadas e quaisquer
# transações em andamento são abortadas, permitindo que o PostgreSQL pare de forma limpa e
# escreva as tabelas em disco, o que é o melhor compromisso disponível para evitar corrupção
# de dados.
#
# Usuários que sabem que suas aplicações não mantêm conexões inativas de longa duração
# podem querer usar um valor de SIGTERM em vez disso, que corresponde ao "Modo
# de Desligamento Inteligente", no qual quaisquer sessões existentes são permitidas a finalizar e o
# servidor para quando todas as sessões são terminadas.
#
STOPSIGNAL SIGINT
#
# Uma configuração adicional que é recomendada para todos os usuários, independentemente deste
# valor, é o tempo de execução "--stop-timeout" (ou o equivalente no seu orquestrador/tempo de
# execução) para controlar quanto tempo esperar entre o envio do STOPSIGNAL definido e o
# envio do SIGKILL (o que provavelmente causará corrupção de dados).
#
# O padrão na maioria dos tempos de execução (como o Docker) é 10 segundos, e a
# documentação em https://www.postgresql.org/docs/12/server-start.html observa
# que mesmo 90 segundos podem não ser suficientes em muitos casos.

EXPOSE 5432
CMD ["postgres"]