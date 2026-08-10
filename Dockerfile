# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

FROM ubuntu:latest

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
# negotiated per licensee rather than attached here, and no scanner would know what to do with it
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"

RUN apt-get update

# lm-sensors is used to read the CPUs' own "high" temperature, which is the default CPU_TEMPERATURE_THRESHOLD
RUN apt-get install ipmitool lm-sensors -y

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
