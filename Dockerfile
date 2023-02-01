FROM ubuntu:latest

LABEL org.opencontainers.image.authors="tigerblue77"

RUN apt-get update

RUN apt-get install ipmitool -y

ADD Dell_iDRAC_fan_controller.sh /Dell_iDRAC_fan_controller.sh

RUN chmod 0777 /Dell_iDRAC_fan_controller.sh

# you should override these default values when running. See README.md
#ENV IDRAC_HOST 192.168.1.100
ENV IDRAC_HOST local
#ENV IDRAC_USERNAME root
#ENV IDRAC_PASSWORD calvin
ENV FAN_SPEED 5
ENV CPU_TEMPERATURE_TRESHOLD 50
ENV CHECK_INTERVAL 60
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE false

CMD ["/Dell_iDRAC_fan_controller.sh"]
