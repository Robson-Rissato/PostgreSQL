# PostgreSQL

docker build -t postgres_image .

docker run -d \
  --name meu-postgres \
  -e POSTGRES_PASSWORD=minhasenhasecreta \
  -p 5432:5432 \
  postgres_image

docker run -it \
  -e POSTGRES_PASSWORD=your_password \
  -p 5432:5432 \
  postgres_image
