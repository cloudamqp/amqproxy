FROM alpine:latest
COPY --from=ghcr.io/shopify/toxiproxy:latest ./toxiproxy-cli /toxiproxy-cli
COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
