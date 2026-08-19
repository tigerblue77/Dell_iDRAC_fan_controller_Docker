# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Named so the publishing workflows can build from the exact base digest they
# resolved and recorded as org.opencontainers.image.base.digest, instead of
# letting this line resolve "latest" a second time. Those two resolutions are
# minutes apart, so when Canonical published in between, the image went out
# built on the newer base and labelled with the older one.
# The label lags, it never leads : the resolution always precedes the build. So
# the cost is a nightly base image refresh that rebuilds an image already
# sitting on the current base, not one that skips an image that is not - a
# wasted rebuild rather than a missed security fix.
# Pinning also keeps that workflow's test build and its publishing build on one
# digest, which is what makes "the suite ran on the bytes that get pushed" true
# rather than merely likely.
# The default keeps a plain "docker build ." working, which is how the test
# suite builds it
ARG BASE_IMAGE=ubuntu:latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.authors="tigerblue77"
LABEL org.opencontainers.image.title="Dell iDRAC fan controller"
LABEL org.opencontainers.image.description="Control the fan speed of a Dell PowerEdge server from its CPU temperatures, through IPMI"
LABEL org.opencontainers.image.url="https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker"
LABEL org.opencontainers.image.source="https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker"
LABEL org.opencontainers.image.documentation="https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker#readme"
# The image is the object form of an AGPL program, so it has to carry both the terms it is conveyed
# under and a pointer to its source : this label and image.source above are what a scanner reads, and
# the files copied into /app below are what a human reads. The identifier names the AGPL alone because
# that is the licence this published image is conveyed under ; the commercial alternative is
# negotiated per licensee rather than attached here, and no scanner would know what to do with it.
#
# These labels hold for anyone running "docker build" on this file, which is what the README tells
# contributors to do. They do NOT survive a release : docker/metadata-action generates its own set,
# build_and_publish_docker_image.yml hands it to build-push-action as --label arguments, and those win
# over a LABEL instruction. That workflow therefore states the licence identifier itself, and the two
# have to be changed together
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"

# The three commands are one RUN because the layer, not the filesystem, is what gets pulled : deleting
# /var/lib/apt/lists from a later layer would hide the package lists without making this one any
# smaller, and they would still be transferred. Merged, they are never committed in the first place.
# apt-get install keeps its recommends on purpose - dropping them is a change to what is installed,
# not to what is shipped, and is argued in its own right rather than smuggled in beside a size fix
# lm-sensors is used to read the CPUs' own "high" temperature, which is the default CPU_TEMPERATURE_THRESHOLD
# perl and libio-socket-ssl-perl are the HTTPS client : Redfish is HTTPS and the base image ships no client
# at all - no curl, no wget, no openssl, no python3. perl and its core HTTP::Tiny already arrive here as a
# recommends of lm-sensors, so only the TLS layer is really added, about 2 MB against curl's 13.5 MB and its
# 24 packages of dependency surface. perl is named explicitly all the same rather than relied upon as
# somebody else's recommends, so that a later --no-install-recommends cannot silently take it away
RUN apt-get update \
 && apt-get install ipmitool lm-sensors perl libio-socket-ssl-perl -y \
 && rm -rf /var/lib/apt/lists/*

# AGPL section 4 asks that the notices travel with every copy conveyed, and an image is a copy. They
# are added before the scripts so that a change to a script does not invalidate their layer
ADD LICENSE /app/LICENSE
ADD LICENSE-COMMERCIAL.md /app/LICENSE-COMMERCIAL.md
ADD NOTICE /app/NOTICE

ADD functions.sh /app/functions.sh
ADD constants.sh /app/constants.sh
ADD healthcheck.sh /app/healthcheck.sh
ADD Dell_iDRAC_fan_controller.sh /app/Dell_iDRAC_fan_controller.sh
ADD supervisor.sh /app/supervisor.sh

RUN chmod 0755 /app/functions.sh /app/healthcheck.sh /app/Dell_iDRAC_fan_controller.sh /app/supervisor.sh

WORKDIR /app

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 CMD [ "/app/healthcheck.sh" ]

# you should override these default values when running. See README.md
# ENV IDRAC_HOST=192.168.1.100
ENV IDRAC_HOST=local
# ENV IDRAC_USERNAME=root
# ENV IDRAC_PASSWORD=calvin
ENV FAN_SPEED=5
ENV CPU_TEMPERATURE_THRESHOLD=auto
ENV CPU_TEMPERATURE_SOURCE=auto
ENV CHECK_INTERVAL=5
# Give up on an iDRAC that has been unreachable for this long, so a restart policy can retry with a
# fresh IPMI session. Empty disables it. See the README on what this does and does not protect
ENV MAXIMUM_IPMI_UNREACHABLE_DURATION=60s
# Same threshold expressed in cycles instead. Empty unless you want it exact ; it wins when set
ENV MAXIMUM_CONSECUTIVE_IPMI_FAILURES=
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
ENV KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
ENV MONITORING_ONLY_MODE=false

ENTRYPOINT ["./supervisor.sh"]
