FROM alpine

RUN apk add --update curl bash jq bc \
    && rm -rf /var/cache/apk/*

RUN cd /usr/local/bin \
    && curl -O https://storage.googleapis.com/kubernetes-release/release/v1.6.2/bin/linux/amd64/kubectl \
    && chmod 755 /usr/local/bin/kubectl

COPY autoscale.sh /bin/autoscale.sh
RUN chmod +x /bin/autoscale.sh

ENV INTERVAL 30
ENV LOGS HIGH

CMD ["bash", "/bin/autoscale.sh"]
