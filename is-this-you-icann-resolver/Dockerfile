FROM alpine:3.24

RUN apk update
RUN apk upgrade

RUN apk add unbound

RUN rm -rf /run /tmp
RUN ln -s /dev/shm /run
RUN ln -s /dev/shm /tmp

RUN rm -f /var/cache/apk/*

COPY etc/inittab /etc/inittab
COPY etc /usr/local/etc/
COPY bin /usr/local/bin/

COPY build.txt /usr/local/etc/build.txt
CMD [ "/usr/local/bin/start_up" ]
