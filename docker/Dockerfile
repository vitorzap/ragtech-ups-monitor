FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    autopoint \
    gettext \
    python3 \
    perl \
    libusb-1.0-0-dev \
    libltdl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG NUT_COMMIT=1c4ab78c615a7b2b8231bdb023d553abd64b541d

WORKDIR /opt/nut

RUN git init . \
    && git remote add origin https://github.com/networkupstools/nut.git \
    && git fetch --depth 1 origin "${NUT_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${NUT_COMMIT}" \
    && test -f drivers/ragtech.c

RUN ./autogen.sh \
    && ./configure \
        --prefix=/opt/nut-install \
        --sysconfdir=/etc/nut \
        --with-drivers=ragtech \
        --without-docs \
    && make -j2 \
    && make install

ENV PATH="/opt/nut-install/bin:/opt/nut-install/sbin:${PATH}"

CMD ["/bin/bash"]
