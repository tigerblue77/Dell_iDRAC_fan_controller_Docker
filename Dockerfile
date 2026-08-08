FROM ubuntu:latest

LABEL org.opencontainers.image.authors="tigerblue77"

RUN apt-get update

RUN apt-get install ipmitool -y

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
ENV CPU_TEMPERATURE_THRESHOLD=50
ENV CHECK_INTERVAL=5
# Hand control back to iDRAC above this intake air temperature. 35°C is the ASHRAE A2 allowable
# ceiling, the class the volume PowerEdge line is rated to, so above it a standard server is outside
# its rated envelope while this container holds its fans at a fixed speed.
# Raise it to 40 or 45 on an ASHRAE A3/A4 (Dell Fresh Air) machine, or set it empty to disable the
# check entirely and keep the previous CPU-only behaviour
ENV HIGH_INLET_TEMPERATURE_THRESHOLD=35
# Low temperature protection, opt-in: left empty, its checks stay disabled
ENV LOW_INLET_TEMPERATURE_THRESHOLD=
ENV LOW_CPU_TEMPERATURE_THRESHOLD=
ENV LOW_TEMPERATURE_FAN_SPEED=
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
ENV KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
ENV MONITORING_ONLY_MODE=false

ENTRYPOINT ["./Dell_iDRAC_fan_controller.sh"]
