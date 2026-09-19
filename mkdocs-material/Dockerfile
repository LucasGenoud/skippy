FROM squidfunk/mkdocs-material:latest AS build
WORKDIR /site
COPY mkdocs.yml ./
COPY docs ./docs
RUN mkdocs build --strict

FROM nginx:alpine
COPY --from=build /site/site /usr/share/nginx/html
EXPOSE 80
