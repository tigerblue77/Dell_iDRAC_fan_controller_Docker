<div id="top"></div>

# Dell iDRAC fan controller Docker image

## Table of contents
<ol>
  <li><a href="#container-console-log-example">Container console log example</a></li>
  <li><a href="#requirements">Requirements</a></li>
  <li><a href="#supported-architectures">Supported architectures</a></li>
  <li><a href="#download-docker-image">Download Docker image</a></li>
  <li><a href="#usage">Usage</a></li>
  <li><a href="#parameters">Parameters</a></li>
  <li><a href="#troubleshooting">Troubleshooting</a></li>
  <li><a href="#contributing">Contributing</a></li>
  <li><a href="#license">License</a></li>
</ol>

## Container console log example

![image](https://user-images.githubusercontent.com/37409593/216442212-d2ad7ff7-0d6f-443f-b8ac-c67b5f613b83.png)

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- REQUIREMENTS -->
## Requirements
### iDRAC version

This Docker container only works on Dell PowerEdge servers that support IPMI commands, i.e. < iDRAC 9 firmware 3.30.30.30.

### To access iDRAC over LAN (not needed in "local" mode) :

1. Log into your iDRAC web console

![001](https://user-images.githubusercontent.com/37409593/210168273-7d760e47-143e-4a6e-aca7-45b483024139.png)

2. In the left side menu, expand "iDRAC settings", click "Network" then click "IPMI Settings" link at the top of the web page.

![002](https://user-images.githubusercontent.com/37409593/210168249-994f29cc-ac9e-4667-84f7-07f6d9a87522.png)

3. Check the "Enable IPMI over LAN" checkbox then click "Apply" button.

![003](https://user-images.githubusercontent.com/37409593/210168248-a68982c4-9fe7-40e7-8b2c-b3f06fbfee62.png)

4. Test access to IPMI over LAN running the following commands :
```bash
apt -y install ipmitool
ipmitool -I lanplus \
  -H <iDRAC IP address> \
  -U <iDRAC username> \
  -P <iDRAC password> \
  sdr elist all
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- SUPPORTED ARCHITECTURES -->
## Supported architectures

This Docker container is currently built and available for the following CPU architectures :
- AMD64
- ARM64

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- DOWNLOAD DOCKER IMAGE -->
## Download Docker image

- [Docker Hub](https://hub.docker.com/r/tigerblue77/dell_idrac_fan_controller)
- [GitHub Containers Repository](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/pkgs/container/dell_idrac_fan_controller)

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- USAGE -->
## Usage

1. with local iDRAC:

```bash
docker run -d \
  --name Dell_iDRAC_fan_controller \
  --restart=unless-stopped \
  -e IDRAC_HOST=local \
  -e FAN_SPEED=<decimal or hexadecimal fan speed> \
  -e CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold> \
  -e CHECK_INTERVAL=<seconds between each check> \
  -e DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false> \
  -e CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=<decimal temperature lower threshold, olny when interpolation enabled> \
  -e HIGH_FAN_SPEED=<decimal or hexadecimal fan speed, only when interpolation enabled> \
  -e KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false> \
  --device=/dev/ipmi0:/dev/ipmi0:rw \
  tigerblue77/dell_idrac_fan_controller:latest
```

2. with LAN iDRAC:

```bash
docker run -d \
  --name Dell_iDRAC_fan_controller \
  --restart=unless-stopped \
  -e IDRAC_HOST=<iDRAC IP address> \
  -e IDRAC_USERNAME=<iDRAC username> \
  -e IDRAC_PASSWORD=<iDRAC password> \
  -e FAN_SPEED=<decimal or hexadecimal fan speed> \
  -e CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold> \
  -e CHECK_INTERVAL=<seconds between each check> \
  -e DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false> \
  -e CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=<decimal temperature lower threshold, only when interpolation enabled> \
  -e HIGH_FAN_SPEED=<decimal or hexadecimal fan speed, only when interpolation enabled> \
  -e KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false> \
  tigerblue77/dell_idrac_fan_controller:latest
```
`docker-compose.yml` examples:

1. to use with local iDRAC:

```yml
version: '3.8'

services:
  Dell_iDRAC_fan_controller:
    image: tigerblue77/dell_idrac_fan_controller:latest
    container_name: Dell_iDRAC_fan_controller
    restart: unless-stopped
    environment:
      - IDRAC_HOST=local
      - FAN_SPEED=<decimal or hexadecimal fan speed>
      - CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold>
      - CHECK_INTERVAL=<seconds between each check>
      - DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false>
      - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=<decimal temperature lower threshold, only when interpolation enabled>
      - HIGH_FAN_SPEED=<decimal or hexadecimal fan speed when interpolation enabled>
      - KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false>
    devices:
      - /dev/ipmi0:/dev/ipmi0:rw
```

2. to use with LAN iDRAC:

```yml
version: '3.8'

services:
  Dell_iDRAC_fan_controller:
    image: tigerblue77/dell_idrac_fan_controller:latest
    container_name: Dell_iDRAC_fan_controller
    restart: unless-stopped
    environment:
      - IDRAC_HOST=<iDRAC IP address>
      - IDRAC_USERNAME=<iDRAC username>
      - IDRAC_PASSWORD=<iDRAC password>
      - FAN_SPEED=<decimal or hexadecimal fan speed>
      - CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold>
      - CHECK_INTERVAL=<seconds between each check>
      - DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false>
      - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=<decimal temperature lower threshold, only when interpolation enabled>
      - HIGH_FAN_SPEED=<decimal or hexadecimal fan speed when interpolation enabled>
      - KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false>
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- PARAMETERS -->
## Parameters

All parameters are optional as they have default values (including default iDRAC username and password).

- `IDRAC_HOST` parameter can be set to "local" or to your distant iDRAC's IP address. **Default** value is "local".
- `IDRAC_USERNAME` parameter is only necessary if you're adressing a distant iDRAC. **Default** value is "root".
- `IDRAC_PASSWORD` parameter is only necessary if you're adressing a distant iDRAC. **Default** value is "calvin".
- `FAN_SPEED` parameter can be set as a decimal (from 0 to 100%) or hexadecimaladecimal value (from 0x00 to 0x64) you want to set the fans to. **Default** value is 5(%).
- `CPU_TEMPERATURE_THRESHOLD` parameter is the T°junction (junction temperature) threshold beyond which the Dell fan mode defined in your BIOS will become active again (to protect the server hardware against overheat). **Default** value is 50(°C).
- `CHECK_INTERVAL` parameter is the time (in seconds) between each temperature check and potential profile change. **Default** value is 60(s).
- `DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE` parameter is a boolean that allows to disable third-party PCIe card Dell default cooling response. **Default** value is false.

If you want to enable fan speed interpolation, add the following parameters :
- `CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION` parameter enables fan speed interpolation once exceeded. Fan speed interpolation will increase your fan speed proportionally to **HIGH_FAN_SPEED** until **CPU_TEMPERATURE_THRESHOLD** is reached. This parameter must be lower than **CPU_TEMPERATURE_THRESHOLD**. **Default** value is 40(°C).
- `HIGH_FAN_SPEED` parameter is the fan speed that will be set at `CPU_TEMPERATURE_THRESHOLD`. In other words, it defines maximum fan speed before swiching to the Dell fan mode (see `CPU_TEMPERATURE_THRESHOLD` parameter). **Default** value is 40(%).

Example of how interpolation works:
- `FAN_SPEED` = 10
- `HIGH_FAN_SPEED` = 50
- `CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION` = 30
- `CPU_TEMPERATURE_THRESHOLD` = 70

| CPU temperature |    Fan speed     |
| --------------- | ---------------- |
| 15 °C           | 10 %             |
| 30 °C           | 10 %             |
| 35 °C           | 15 %             |
| 50 °C           | 30 %             |
| 69 °C           | 49 %             |
| 70 °C           | Dell fan control |
| 80 °C           | Dell fan control |

When using fan speed interpolation, we recommend decreasing **CHECK_INTERVAL**, for example "3" (seconds), to avoid the noise nuisance associated with a sudden increase in fan speed.
- `KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT` parameter is a boolean that allows to keep the third-party PCIe card Dell default cooling response state upon exit. **Default** value is false, so that it resets the third-party PCIe card Dell default cooling response to Dell default.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- TROUBLESHOOTING -->
## Troubleshooting

If your server frequently switches back to the default Dell fan mode:
1. Check `Tcase` (case temperature) of your CPU on Intel Ark website and then set `CPU_TEMPERATURE_THRESHOLD` to a slightly lower value. Example with my CPUs ([Intel Xeon E5-2630L v2](https://www.intel.com/content/www/us/en/products/sku/75791/intel-xeon-processor-e52630l-v2-15m-cache-2-40-ghz/specifications.html)) : Tcase = 63°C, I set `CPU_TEMPERATURE_THRESHOLD` to 60(°C).
2. If it's already good, adapt your `FAN_SPEED` value to increase the airflow and thus further decrease the temperature of your CPU(s) or enable and experiment with fan speed interpolation
3. If neither increasing the fan speed nor increasing the threshold solves your problem, then it may be time to replace your thermal paste

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- LICENSE -->
## License

Shield: [![CC BY-NC-SA 4.0][cc-by-nc-sa-shield]][cc-by-nc-sa]

This work is licensed under a
[Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License][cc-by-nc-sa]. The full license description can be read [here][link-to-license-file].

[![CC BY-NC-SA 4.0][cc-by-nc-sa-image]][cc-by-nc-sa]

[cc-by-nc-sa]: http://creativecommons.org/licenses/by-nc-sa/4.0/
[cc-by-nc-sa-image]: https://licensebuttons.net/l/by-nc-sa/4.0/88x31.png
[cc-by-nc-sa-shield]: https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg
[link-to-license-file]: ./LICENSE

<p align="right">(<a href="#top">back to top</a>)</p>
