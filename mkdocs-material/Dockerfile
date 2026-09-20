FROM squidfunk/mkdocs-material:latest AS build
WORKDIR /site
COPY mkdocs.yml ./
COPY docs ./docs
COPY overrides ./overrides
RUN mkdocs build --strict

FROM nginx:alpine
COPY --from=build /site/site /usr/share/nginx/html
RUN sed -i 's/listen[[:space:]]*80;/listen 8123;/' /etc/nginx/conf.d/default.conf
EXPOSE 8123
