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
  -e CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold, or auto> \
  -e CHECK_INTERVAL=<seconds between each check> \
  -e DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false> \
  -e KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false> \
  -e MONITORING_ONLY_MODE=<true or false> \
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
  -e CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold, or auto> \
  -e CHECK_INTERVAL=<seconds between each check> \
  -e DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false> \
  -e KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false> \
  -e MONITORING_ONLY_MODE=<true or false> \
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
      - CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold, or auto>
      - CHECK_INTERVAL=<seconds between each check>
      - DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false>
      - KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false>
      - MONITORING_ONLY_MODE=<true or false>
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
      - CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold, or auto>
      - CHECK_INTERVAL=<seconds between each check>
      - DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false>
      - KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false>
      - MONITORING_ONLY_MODE=<true or false>
```

For security reasons, it is recommended to store your credentials in a `.env` file instead of hardcoding them in a `docker run` command or a `docker-compose.yml` file. Copy [`.env.example`](./.env.example) to `.env`, fill in your values, then reference it:

- with `docker run`:

```bash
docker run -d \
  --name Dell_iDRAC_fan_controller \
  --restart=unless-stopped \
  --env-file .env \
  tigerblue77/dell_idrac_fan_controller:latest
```

- with `docker-compose.yml`:

```yml
version: '3.8'

services:
  Dell_iDRAC_fan_controller:
    image: tigerblue77/dell_idrac_fan_controller:latest
    container_name: Dell_iDRAC_fan_controller
    restart: unless-stopped
    env_file:
      - .env
```

(if using local iDRAC, add the `devices:` section shown in the examples above)

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- PARAMETERS -->
## Parameters

All parameters are optional as they have default values (including default iDRAC username and password).

- `IDRAC_HOST` parameter can be set to "local" or to your distant iDRAC's IP address. **Default** value is "local".
- `IDRAC_USERNAME` parameter is only necessary if you're adressing a distant iDRAC. **Default** value is "root".
- `IDRAC_PASSWORD` parameter is only necessary if you're adressing a distant iDRAC. **Default** value is "calvin".
- `FAN_SPEED` parameter can be set as a decimal (from 0 to 100%) or hexadecimaladecimal value (from 0x00 to 0x64) you want to set the fans to. **Default** value is 5(%).
- `CPU_TEMPERATURE_THRESHOLD` parameter is the T°junction (junction temperature) threshold beyond which the Dell fan mode defined in your BIOS will become active again (to protect the server hardware against overheat). It can be set to a decimal number of degrees Celsius, or to "auto" to let the container read the threshold from the CPUs themselves. **Default** value is "auto".
  - In "auto" mode, the threshold is the "high" temperature your CPU manufacturer defined, as reported by the [`lm-sensors`](https://github.com/lm-sensors/lm-sensors) utility (the `high = +62.0°C` value below), which is far more relevant than a single fixed value shared by every CPU model :

    ```
    coretemp-isa-0000
    Adapter: ISA adapter
    Package id 0:  +45.0°C  (high = +62.0°C, crit = +72.0°C)
    Core 0:        +44.0°C  (high = +62.0°C, crit = +72.0°C)
    ```

    "high" is the temperature at which your CPU expects cooling to be at full, and it always sits below "crit", the temperature at which the CPU throttles itself — so it is the one that leaves the fans time to act. How far below varies a lot by CPU model : 10°C on the example above, but only 2°C on a PowerEdge T630 reporting `high = +83.0°C, crit = +85.0°C`. On a multi-socket server, the lowest "high" value of all detected CPUs is used as the threshold — note that only CPU 1 and CPU 2 temperatures are currently compared against it.
  - Automatic detection is only available in "local" mode : `lm-sensors` reads the CPUs of the machine the container runs on, which is the controlled server itself only in that mode. It also requires your Docker host's kernel to expose CPU temperatures through `/sys` (the `coretemp` module).
  - Automatic detection only works on **Intel** CPUs. AMD's `k10temp` driver publishes no "high" value at all on Zen parts (every EPYC server), and on older parts it publishes a fixed 70°C that is a Linux driver constant rather than an AMD specification, so it is deliberately ignored. AMD servers use the fallback value below.
  - Whenever the threshold can't be detected, the container falls back to 50(°C) and logs why at startup.
  - :warning: **This default changed.** Previous versions used a fixed 50°C. On Intel servers in "local" mode, "auto" typically resolves to a **higher** value (roughly 62 to 96°C depending on the CPU model — read the exact one from the startup log), so the fans stay at `FAN_SPEED` longer than they used to before Dell's profile takes over. This matches what your CPU actually asks for, but it also means the whole chassis runs at `FAN_SPEED` for longer, and the CPU is the only component this container watches. If you were relying on the old behaviour, set `CPU_TEMPERATURE_THRESHOLD=50` explicitly.
- `CHECK_INTERVAL` parameter is the time between each temperature check and potential profile change, in seconds unless a unit suffix (`s`, `m`, `h` or `d`) says otherwise, so `90`, `90s` and `5m` are all valid. Fractions of a second are not. The container refuses to start on a value `sleep` cannot wait for, and on zero, as either would leave the monitoring loop unpaced and running at full speed against your iDRAC. **Default** value is 5(s). A short interval makes the controller react quickly to temperature spikes, at the cost of more IPMI traffic towards the iDRAC and more container log lines. If your iDRAC struggles to keep up (especially over LAN) or if you prefer quieter logs, increase this value.

  This interval is also the controller's reaction time, so it is bounded from above. While your fan control profile is applied, Dell's own dynamic fan control is disabled and the fans are pinned at `FAN_SPEED`: nothing raises them until the *next* check reads a temperature above `CPU_TEMPERATURE_THRESHOLD`. The interval is therefore the longest your server can heat up with its cooling frozen at a speed you chose for an idle machine. Above **60 seconds** the container starts and prints a warning saying so. Above **15 minutes** it refuses to start, that delay being long enough that the controller is not really controlling anything anymore.

  Both limits are lifted by `MONITORING_ONLY_MODE`, where no profile is ever applied, Dell's dynamic fan control keeps the fans and the interval is only how often temperatures are logged. If you want a slow polling cadence for logging purposes, that is the mode to use.
- `DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE` parameter is a boolean that allows to disable third-party PCIe card Dell default cooling response. **Default** value is false.
- `KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT` parameter is a boolean that allows to keep the third-party PCIe card Dell default cooling response state upon exit. **Default** value is false, so that it resets the third-party PCIe card Dell default cooling response to Dell default.
- `MONITORING_ONLY_MODE` parameter is a boolean that allows to run the container in a read-only, monitoring-only mode: temperatures are still read and logged at each `CHECK_INTERVAL`, but no fan control profile (neither the user-defined one nor Dell's default) and no third-party PCIe card cooling response change is ever sent to the server. Useful to observe temperatures and validate your `FAN_SPEED`/`CPU_TEMPERATURE_THRESHOLD` values before letting the container actually take control of the fans. **Default** value is false.

The three boolean parameters above accept **only the lowercase literals `true` and `false`**, and the container refuses to start on anything else — `True`, `TRUE`, `1`, `on` and `yes` included. This is not pickiness: these parameters are dispatched by running their value, so those spellings used to be taken as `false` without a word. `MONITORING_ONLY_MODE=True` would take control of the fans on a server you had explicitly asked the container to leave alone, while logging "Monitoring only mode: Disabled".

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- TROUBLESHOOTING -->
## Troubleshooting

### Your server frequently switches back to the default Dell fan mode:
1. Check `Tcase` (case temperature) of your CPU on Intel Ark website and then set `CPU_TEMPERATURE_THRESHOLD` to a slightly lower value. Example with my CPUs ([Intel Xeon E5-2630L v2](https://www.intel.com/content/www/us/en/products/sku/75791/intel-xeon-processor-e52630l-v2-15m-cache-2-40-ghz/specifications.html)) : Tcase = 63°C, I set `CPU_TEMPERATURE_THRESHOLD` to 60(°C). Note that the default "auto" value does **not** do this for you : Tcase is a case (heat spreader) temperature, while "auto" uses the junction-scale "high" value, which is usually well above Tcase (on a Xeon Gold 5122 for instance, Tcase is 71°C but "high" is around 94°C). If you want a Tcase-derived threshold, set it explicitly. The startup log always states which threshold was picked and where it comes from.
2. If it's already good, adapt your `FAN_SPEED` value to increase the airflow and thus further decrease the temperature of your CPU(s)
3. If neither increasing the fan speed nor increasing the threshold solves your problem, then it may be time to replace your thermal paste

### You get `/!\ Your server isn't a Dell product. Exiting.` error on UnRAID OS

- Run the image using usual `docker run` command instead of UnRAID Community Apps or Docker UI. [More informations here.](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/89#issuecomment-4166458799)

### Not all of your CPUs appear in the temperatures table

At startup, the container logs the CPU temperature sensors it found, with the IPMI entities they were read from (`4 CPU temperature sensors detected (entities 3.1 3.2 3.3 3.4).`), and prints one column per detected CPU. There is no built-in limit on that number, so 4-socket servers (R930, R830, R920, R940...) get all of their CPUs monitored.

If fewer sensors are listed than the number of CPUs installed, your iDRAC isn't reporting the missing sockets as readable IPMI processor entities. Check what it does report with :
```bash
ipmitool -I lanplus \
  -H <iDRAC IP address> \
  -U <iDRAC username> \
  -P <iDRAC password> \
  sdr type temperature
```
CPUs are the lines whose 4th column is an entity `3.<something>` and whose reading ends in `degrees C`. They need not be contiguous nor in order: a socket that is empty or unreadable is usually still listed, but as `Disabled` or `No Reading` instead of a temperature, and is therefore not monitored. Please [open an issue](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues) with your server model and that output if a CPU that does report a temperature is missing from the table.

The container follows those sensors while it runs, so there is no need to restart it after changing the CPUs of the target server. A CPU that starts reporting a temperature is picked up and monitored on the next check.

A CPU that stops reporting one keeps its column, reading `-`, and the Dell default fan control profile is applied meanwhile, since its temperature is unknown. It is only dropped from the table if it is still silent on several consecutive checks after the server has been switched off and back on, that being the only way a CPU can physically leave the machine: a sensor going quiet on a running server is a fault, not a missing socket, and dropping it would silently stop watching a CPU that is still installed. The conclusion is logged as such :
```
CPU 3 and CPU 4 are considered removed from the server: their temperature sensors (entities 3.3 and 3.4) reported nothing on the 5 readings that followed the server powering back on. 2 CPU temperature sensors detected (entities 3.1 3.2).
```
Several agreeing readings are required because a populated socket can still be unreadable for a few checks after a reboot, while its iDRAC reports it exactly like a socket that is gone. Following the CPUs this way costs no extra IPMI command: it reuses the sensor data each cycle already reads.

Note that on chassis products (VRTX, FX2, M1000e, MX7000) each server node has its own iDRAC with its own address: point the container at a node's iDRAC, not at the chassis CMC, which doesn't answer IPMI at all.

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

To test locally, use either :
```bash
docker build -t tigerblue77/dell_idrac_fan_controller:dev .
docker run -d ...
```
or
```bash
export IDRAC_HOST=<iDRAC IP address>
export IDRAC_USERNAME=<iDRAC username>
export IDRAC_PASSWORD=<iDRAC password>
export FAN_SPEED=<decimal or hexadecimal fan speed>
export CPU_TEMPERATURE_THRESHOLD=<decimal temperature threshold, or auto>
export CHECK_INTERVAL=<seconds between each check>
export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=<true or false>
export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=<true or false>
export MONITORING_ONLY_MODE=<true or false>

chmod +x Dell_iDRAC_fan_controller.sh
./Dell_iDRAC_fan_controller.sh
```

### Automated tests

The repository ships an automated test suite that runs the controller against a mocked `ipmitool`, so it needs **no Dell hardware, no iDRAC and no network** : `bash`, `coreutils`, GNU `grep` and `awk` are enough.

```bash
./tests/run_tests.sh                 # run everything
./tests/run_tests.sh --list          # list the test cases without running them
./tests/run_tests.sh -f temperature  # only run the test cases whose name matches
./tests/run_tests.sh --tap           # emit TAP output for a CI parser
```

It covers every PowerEdge generation from the 9th (2006) to the 17th (2024) — including the recent ones whose firmware no longer accepts Dell's IPMI raw fan control commands — in their single, dual and quad socket variants, plus the sensor layouts they report (missing exhaust sensor, empty second socket, unreadable reading, two-digit sensor IDs...).

Blades and modular servers are covered too : the M1000e and VRTX blades, the FX2 and MX7000 sleds and the nodes of a C-series chassis. They carry no fan of their own — the enclosure does, driven by its CMC — so this container cannot cool them, and the suite pins what it does instead : identify the server, report that the fan control commands were rejected, and keep monitoring.

The suite also runs on every push and pull request through the [`Tests`](.github/workflows/tests.yml) workflow, both directly and inside the built Docker image. Each run publishes a report on the pull request : the test count compared against the base commit, and, behind the check run, every test case that ran with what a failing one expected and what it obtained. See [`tests/README.md`](./tests/README.md) for the layout and for how to add a test case.

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
