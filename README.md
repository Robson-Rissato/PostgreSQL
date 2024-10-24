# PostgreSQL

docker build -t postgres_image .
<br>
-t postgres_image: Atribui um nome e tag à sua imagem Docker.
<br>
docker run -d \
  --name meu-postgres \
  -e POSTGRES_PASSWORD=minhasenhasecreta \
  -p 5432:5432 \
  postgres_image
<br>
-d: Executa o container em segundo plano.
--name meu-postgres: Nomeia o container para facilitar a referência.
-e POSTGRES_PASSWORD=...: Define a senha do usuário postgres.
-p 5432:5432: Mapeia a porta 5432 do container para a porta 5432 da sua máquina.
<br>
docker run -it \
  -e POSTGRES_PASSWORD=your_password \
  -p 5432:5432 \
  postgres_image
