# syntax=docker/dockerfile:1
# Pin FLUTTER_IMAGE to the exact Flutter version you develop with (e.g. ghcr.io/cirruslabs/flutter:3.47.7).
ARG FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:stable
FROM ${FLUTTER_IMAGE} AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# Same-origin API by default: nginx proxies /api to the backend.
ARG API_BASE_URL=/api/v1
ARG APP_NAME="App Management Platform"
RUN flutter build web --release --dart-define=API_BASE_URL=${API_BASE_URL} --dart-define=APP_NAME="${APP_NAME}"

FROM nginx:1.29-alpine
COPY --from=build /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/templates/default.conf.template
ENV API_UPSTREAM=http://backend:4000
EXPOSE 80
