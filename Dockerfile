FROM ghcr.io/nezhahq/nezha AS app

FROM nginx:stable-alpine

RUN apk add --no-cache tar gzip tzdata openssl sqlite sqlite-dev dcron coreutils git curl

COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY --from=app /etc/ssl/certs /etc/ssl/certs

COPY main.conf /etc/nginx/conf.d/main.conf

WORKDIR /dashboard

COPY --from=app /dashboard/app /dashboard/app

RUN mkdir -p /dashboard/data && chmod -R 777 /dashboard

ENV TZ=Asia/Shanghai \
    ARGO_DOMAIN="" \
    ARGO_AUTH="" \
    GITHUB_TOKEN="" \
    GITHUB_REPO_OWNER="" \
    GITHUB_REPO_NAME="" \
    BACKUP_BRANCH=""

COPY backup.sh /backup.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /backup.sh && chmod +x /entrypoint.sh

EXPOSE 8008
CMD ["/entrypoint.sh"]
