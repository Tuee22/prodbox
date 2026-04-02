FROM nginx:1.25-alpine
RUN apk add --no-cache nginx-module-njs
