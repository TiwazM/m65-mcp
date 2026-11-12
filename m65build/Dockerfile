# MEGA65 core build tools on top of vivado-on-mac's x86_64 image (x64-linux).
FROM --platform=linux/amd64 x64-linux
USER root
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y build-essential pkg-config git wget python3 \
      unzip imagemagick p7zip-full libusb-1.0-0-dev libgif-dev libpng-dev libgtest-dev \
      libgmock-dev libreadline-dev libtinfo5 libncurses5-dev libcairo2-dev python-is-python3 \
 && apt-get clean
RUN git clone -q https://bitbucket.org/magli143/exomizer.git /tmp/exo \
 && make -C /tmp/exo/src && cp /tmp/exo/src/exomizer /usr/local/bin && rm -rf /tmp/exo
