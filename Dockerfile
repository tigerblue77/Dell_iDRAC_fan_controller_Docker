FROM ubuntu:latest

LABEL org.opencontainers.image.authors="tigerblue77"

RUN apt-get update

# lm-sensors is used to read the CPUs' own "high" temperature, which is the default CPU_TEMPERATURE_THRESHOLD
RUN apt-get install ipmitool lm-sensors -y

ADD functions.sh /app/functions.sh
ADD constants.sh /app/constants.sh
ADD healthcheck.sh /app/healthcheck.sh
ADD Dell_iDRAC_fan_controller.sh /app/Dell_iDRAC_fan_controller.sh

RUN chmod 0777 /app/functions.sh /app/healthcheck.sh /app/Dell_iDRAC_fan_controller.sh

WORKDIR /app

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 CMD [ "/app/healthcheck.sh" ]

# you should override these default values when running. See README.md
# ENV IDRAC_HOST=192.168.1.100
ENV IDRAC_HOST=local
# ENV IDRAC_USERNAME=root
# ENV IDRAC_PASSWORD=calvin
ENV FAN_SPEED=5
ENV CPU_TEMPERATURE_THRESHOLD=auto
ENV CHECK_INTERVAL=5
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
ENV KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
ENV MONITORING_ONLY_MODE=false

ENTRYPOINT ["./Dell_iDRAC_fan_controller.sh"]
