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
  <li><a href="#stopping-the-container">Stopping the container</a></li>
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
  -e CPU_TEMPERATURE_SOURCE=<auto, ipmi or lm-sensors> \
  -e CHECK_INTERVAL=<seconds between each check> \
  -e MAXIMUM_IPMI_UNREACHABLE_DURATION=<how long the iDRAC may stay unreachable before exiting, or empty> \
  -e MAXIMUM_CONSECUTIVE_IPMI_FAILURES=<the same threshold in cycles instead, or empty> \
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
  -e CPU_TEMPERATURE_SOURCE=<auto, ipmi or lm-sensors> \
  -e CHECK_INTERVAL=<seconds between each check> \
  -e MAXIMUM_IPMI_UNREACHABLE_DURATION=<how long the iDRAC may stay unreachable before exiting, or empty> \
  -e MAXIMUM_CONSECUTIVE_IPMI_FAILURES=<the same threshold in cycles instead, or empty> \
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
      - CPU_TEMPERATURE_SOURCE=<auto, ipmi or lm-sensors>
      - CHECK_INTERVAL=<seconds between each check>
      - MAXIMUM_IPMI_UNREACHABLE_DURATION=<how long the iDRAC may stay unreachable before exiting, or empty>
      - MAXIMUM_CONSECUTIVE_IPMI_FAILURES=<the same threshold in cycles instead, or empty>
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
      - CPU_TEMPERATURE_SOURCE=<auto, ipmi or lm-sensors>
      - CHECK_INTERVAL=<seconds between each check>
      - MAXIMUM_IPMI_UNREACHABLE_DURATION=<how long the iDRAC may stay unreachable before exiting, or empty>
      - MAXIMUM_CONSECUTIVE_IPMI_FAILURES=<the same threshold in cycles instead, or empty>
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

    "high" is the temperature at which your CPU expects cooling to be at full, and it always sits below "crit", the temperature at which the CPU throttles itself — so it is the one that leaves the fans time to act. How far below varies a lot by CPU model : 10°C on the example above, but only 2°C on a PowerEdge T630 reporting `high = +83.0°C, crit = +85.0°C`. On a multi-socket server, the lowest "high" value of all detected CPUs is used as the threshold, and every detected CPU is compared against it.
  - Automatic detection is only available in "local" mode : `lm-sensors` reads the CPUs of the machine the container runs on, which is the controlled server itself only in that mode. It also requires your Docker host's kernel to expose CPU temperatures through `/sys` (the `coretemp` module).
  - Automatic detection only works on **Intel** CPUs. AMD's `k10temp` driver publishes no "high" value at all on Zen parts (every EPYC server), and on older parts it publishes a fixed 70°C that is a Linux driver constant rather than an AMD specification, so it is deliberately ignored. AMD servers use the fallback value below.
  - Whenever the threshold can't be detected, the container falls back to 50(°C) and logs why at startup.
  - :warning: **This default changed in v1.28.** Versions up to v1.27 used a fixed 50°C. On Intel servers in "local" mode, "auto" typically resolves to a **higher** value (roughly 62 to 96°C depending on the CPU model — read the exact one from the startup log), so the fans stay at `FAN_SPEED` longer than they used to before Dell's profile takes over. This matches what your CPU actually asks for, but it also means the whole chassis runs at `FAN_SPEED` for longer, and the CPU is the only component this container watches. If you were relying on the old behaviour, set `CPU_TEMPERATURE_THRESHOLD=50` explicitly.
- `CPU_TEMPERATURE_SOURCE` parameter selects where the CPU temperatures the container supervises are read from. **Default** value is "auto".
  - `auto` reads them from your iDRAC, and falls back to [`lm-sensors`](https://github.com/lm-sensors/lm-sensors) only if your iDRAC turns out to report no CPU temperature **at all**. Some older iDRACs accept Dell's raw fan control commands but answer nothing usable to a temperature query ([issue #216](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/216)) : on those, the container used to be able to do nothing but hand the fans back to Dell's own profile forever. The fallback is tried on the check that found no sensor, just before the container would otherwise refuse to run over it, and it is logged when it engages. One check is enough to conclude: an iDRAC that exposes no processor entity does so on every check rather than on that one, which is the same reason the container refuses instead of retrying. Once engaged it stays for the life of the container, that being a property of the firmware rather than a passing condition, and changing the meaning of the table's numbers mid-run would be worse than keeping a source that works.
  - `ipmi` never reads `lm-sensors`, whatever your iDRAC reports. Set it if you want the source to be the iDRAC and nothing else.
  - `lm-sensors` reads them from `lm-sensors` from the start, without waiting for your iDRAC to prove it cannot report them. The container refuses to start if `lm-sensors` reports no CPU temperature, rather than silently supervising nothing.
  - Whatever the source, **fan control still goes through your iDRAC** : `lm-sensors` replaces the readings, not the IPMI commands. A server whose iDRAC rejects `raw 0x30 0x30` cannot be cooled by this container at all, and this parameter changes nothing for it.
  - `lm-sensors` is only available in "local" mode, for the same reason automatic threshold detection is : it reads the CPUs of the machine the container runs on, which is the controlled server itself only in that mode. In network mode, `auto` never falls back and `lm-sensors` is refused at startup.
  - It also only works on **Intel** CPUs, again like threshold detection : AMD's `k10temp` driver reports `Tctl`, a control value that is not the physical temperature your iDRAC reports for the same CPU. On `auto` and `ipmi`, an AMD server therefore keeps reading its CPUs through IPMI; asking explicitly for `lm-sensors` on one makes the container refuse to start rather than supervise nothing.
  - The value is read leniently : case is ignored, surrounding whitespace and quotes are stripped, `lm_sensors` and `lmsensors` are accepted as spellings of `lm-sensors`, and an empty value means `auto`. Anything that is still none of the three stops the container at startup rather than silently meaning `auto`.
  - Your inlet and exhaust temperatures keep coming from your iDRAC : `lm-sensors` has no equivalent for them, so only the CPU rows are replaced. On a server that reports neither, both columns show `-`, which is what they already do today.
- `CHECK_INTERVAL` parameter is the time between each temperature check and potential profile change, in seconds unless a unit suffix (`s`, `m`, `h` or `d`) says otherwise, so `90`, `90s` and `5m` are all valid. Fractions of a second are not. The container refuses to start on a value `sleep` cannot wait for, and on zero, as either would leave the monitoring loop unpaced and running at full speed against your iDRAC. **Default** value is 5(s). A short interval makes the controller react quickly to temperature spikes, at the cost of more IPMI traffic towards the iDRAC and more container log lines. If your iDRAC struggles to keep up (especially over LAN) or if you prefer quieter logs, increase this value.
- `MAXIMUM_IPMI_UNREACHABLE_DURATION` parameter is how long the iDRAC may stay completely unreachable before the container gives up and exits. **Default** value is 60s, in seconds unless a unit suffix (`s`, `m`, `h` or `d`) says otherwise, exactly like `CHECK_INTERVAL`. Empty disables the escalation. It counts only failures to reach the iDRAC: a server correctly reported as powered off is a state that was observed, not a failure, and never counts however long it stays off; any cycle that reaches the iDRAC resets the count. An unreachable iDRAC accepts no command, so exiting cannot and does not try to move the fans — the point is to obtain a fresh IPMI session, which is what clears an expired session, a rebooted iDRAC or an exhausted session limit, and to make the loss visible to `docker ps` and to anything watching container state instead of it being buried in logs. **Read the paragraph below before relying on it.**
  > **This only helps if something restarts the container.** With Docker's default `no` restart policy, a container that exits stays dead: `graceful_exit` tries to restore Dell's profile on the way out, but that command goes through the same unreachable iDRAC and fails too, so the fans keep the speed they were last set to with nothing watching them at all. Worse, a container that keeps retrying recovers on its own the moment the iDRAC answers again, whereas one that exited does not. Run with `--restart unless-stopped` (or a Compose `restart:` policy) if you leave this enabled, or set it empty to keep the previous retry-forever behaviour.
- `MAXIMUM_CONSECUTIVE_IPMI_FAILURES` parameter expresses that same threshold as a raw number of consecutive unreachable cycles instead of a duration. **Default** value is (empty), the duration above being used. When set it takes precedence, being the more specific of the two. Prefer the duration unless you need the count exactly: it keeps meaning the same thing when `CHECK_INTERVAL` changes, where a cycle count silently would not.

  This interval is also the controller's reaction time, so it is bounded from above. While your fan control profile is applied, Dell's own dynamic fan control is disabled and the fans are pinned at `FAN_SPEED`: nothing raises them until the *next* check reads a temperature above `CPU_TEMPERATURE_THRESHOLD`. The interval is therefore the longest your server can heat up with its cooling frozen at a speed you chose for an idle machine. Above **60 seconds** the container starts and prints a warning saying so. Above **15 minutes** it refuses to start, that delay being long enough that the controller is not really controlling anything anymore.

  Both limits are lifted by `MONITORING_ONLY_MODE`, where no profile is ever applied, Dell's dynamic fan control keeps the fans and the interval is only how often temperatures are logged. If you want a slow polling cadence for logging purposes, that is the mode to use.
- `DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE` parameter is a boolean that allows to disable third-party PCIe card Dell default cooling response. **Default** value is false.
- `KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT` parameter is a boolean that allows to keep the third-party PCIe card Dell default cooling response state upon exit. **Default** value is false, so that it resets the third-party PCIe card Dell default cooling response to Dell default.
- `MONITORING_ONLY_MODE` parameter is a boolean that allows to run the container in a read-only, monitoring-only mode: temperatures are still read and logged at each `CHECK_INTERVAL`, but no fan control profile (neither the user-defined one nor Dell's default) and no third-party PCIe card cooling response change is ever sent to the server. Useful to observe temperatures and validate your `FAN_SPEED`/`CPU_TEMPERATURE_THRESHOLD` values before letting the container actually take control of the fans. **Default** value is false.

The three boolean parameters above accept **only the lowercase literals `true` and `false`**, and the container refuses to start on anything else — `True`, `TRUE`, `1`, `on` and `yes` included. This is not pickiness: these parameters are dispatched by running their value, so those spellings used to be taken as `false` without a word. `MONITORING_ONLY_MODE=True` would take control of the fans on a server you had explicitly asked the container to leave alone, while logging "Monitoring only mode: Disabled".

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- STOPPING THE CONTAINER -->
## Stopping the container

While the container runs, the fans are held at your `FAN_SPEED` and the server's own thermal regulation is switched off. **Stopping the container is what gives it back**, so that is not a detail of the shutdown — it is the moment the server stops depending on this container to stay cool.

On `docker stop`, `docker restart`, a host shutdown or a `docker compose down`, the container:

1. applies Dell's default dynamic fan control profile, handing the fans back to the iDRAC;
2. resets the third-party PCIe card cooling response to Dell's default, unless you set `KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=true`;
3. exits.

It says so in the log, and that line is the one to look for when you stop it:

```
/!\ Warning /!\ Container stopped, Dell default dynamic fan control profile applied for safety. Exiting.
```

In `MONITORING_ONLY_MODE` nothing was ever applied, so nothing is restored and no command is sent.

### Give it time to do it

The container's PID 1 is a small supervisor whose only job is to make sure step 1 happens even if the monitoring process cannot do it itself. It forwards the stop signal, gives the monitoring process **3 seconds** to bow out cleanly, kills it if it has not, and then applies Dell's profile on its behalf.

That needs Docker's stop timeout to be **longer than those 3 seconds**. The default is 10 seconds, so nothing has to be configured — but if you shorten it, you can cut the container off before it has handed the fans back:

| Where | Keep it above 3 seconds |
| --- | --- |
| `docker stop -t <seconds>` | the default is 10 |
| `docker run --stop-timeout <seconds>` | the default is 10 |
| `stop_grace_period:` in `docker-compose.yml` | the default is 10s |
| `terminationGracePeriodSeconds:` on Kubernetes | the default is 30 |

Past that timeout the container is `SIGKILL`ed, which no program can catch or delay, and **the fans stay at your `FAN_SPEED` with nothing left to raise them**. The safety net is defeated precisely in the case it exists for, so if you have a reason to stop containers quickly, exclude this one.

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

### None of your CPUs appears in the temperatures table

If your iDRAC reports **no** readable CPU temperature sensor at all, the container has nothing to supervise. Every PowerEdge has at least one CPU, so rather than sit and wait it hands the fans back to Dell's own dynamic profile and refuses to run, naming what to check:

```
/!\ Error /!\ No CPU temperature sensor could be read from DELL PowerEdge R730xd, and every PowerEdge has at least one CPU.
```

`MONITORING_ONLY_MODE=true` is the exception: it drives no fan, so a CPU it cannot read costs it a column and nothing else. It keeps running and logs the chassis temperatures it *can* read, with no CPU column in the table:

```
No CPU temperature sensor detected, only the chassis temperatures will be monitored.
```

Some older iDRACs are in that state permanently: they accept Dell's raw fan control commands but answer nothing usable to a temperature query. In "local" mode, the machine running the container **is** the server, so its CPUs can be read directly instead, through `lm-sensors`. That is what `CPU_TEMPERATURE_SOURCE=auto` (the default) does, on the check that found no sensor and before the container would otherwise refuse to run:

```
08-08-2026 15:04:31  The iDRAC reports no readable CPU temperature sensor, reading the CPUs from lm-sensors instead. Fan control keeps going through the iDRAC.
2 CPU temperature sensors detected (lm-sensors chips coretemp-isa-0000 coretemp-isa-0001).
```

If that line never appears, the fallback couldn't engage. In order:

1. **You're in network mode.** `lm-sensors` reads the machine the container runs on, which isn't the controlled server there. Nothing can replace your iDRAC's readings remotely.
2. **Your Docker host doesn't expose its CPU temperatures.** Check with `docker exec <container name> sensors -u`, which must print a `Package id 0:` block. If it prints nothing, load the `coretemp` kernel module on the host (`modprobe coretemp`) and make sure `/sys` is readable from the container.
3. **Your CPUs are AMD.** `k10temp` reports `Tctl`, a control value that is not the physical temperature your iDRAC reports, so it is deliberately not read. Please [open an issue](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues) with your server model, `sensors -u` and `ipmitool -I open sdr elist all` if you have such a server: hardware output is what's missing to support it.

Whatever the source, **fan control itself always goes through your iDRAC**. If the raw commands are rejected too:

```
/!\ Error /!\ Failed to enable manual fan control. ipmitool said: Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xc1): Invalid command.
```

then no temperature source changes anything: your server's fans cannot be driven through this container. That is expected on blades and sleds, whose fans belong to their enclosure and are driven by its CMC.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes, signed off (`git commit -s -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

Please read [`CONTRIBUTING.md`](./CONTRIBUTING.md) before you do : it explains the sign-off in step 3, and the terms your contribution arrives under in a project that is [dual-licensed](#license).

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
export MAXIMUM_IPMI_UNREACHABLE_DURATION=<how long the iDRAC may stay unreachable before exiting, or empty>
export MAXIMUM_CONSECUTIVE_IPMI_FAILURES=<the same threshold in cycles instead, or empty>
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

[![License: AGPL v3][agpl-shield]][agpl] [![Commercial licence available][commercial-shield]][link-to-commercial-license-file]

This project is dual-licensed.

**By default, it is free software under the [GNU Affero General Public License version 3][agpl]** (`AGPL-3.0-only`). You may use it, study it, modify it and redistribute it, at no cost and with no formality. The one thing asked in return is reciprocity : if you distribute the program — as-is or modified, as scripts, as an image, or inside a product — the people who receive it must get the corresponding source under those same terms. The full text is in [`LICENSE`][link-to-license-file].

Running the container is never restricted. On a homelab, on a company's own servers, in production, at any scale : the AGPL asks nothing of you for that, and no permission is needed.

**A [separate commercial licence][link-to-commercial-license-file] is available** for the parties who cannot meet those obligations — typically a vendor embedding the controller in a product whose source cannot be published, or anyone needing a warranty, an indemnity or a support commitment, none of which the AGPL provides. The choice between the two is yours ; see [`LICENSE-COMMERCIAL.md`][link-to-commercial-license-file].

### What changed, and what it means for you

The project was licensed under CC BY-NC-SA 4.0 until the relicensing tracked in [#304](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/304). Side by side :

**Using it, free of charge**

| | Before — CC BY-NC-SA 4.0 | Now — AGPL-3.0-only |
|---|---|---|
| Run it in a homelab | ✅ | ✅ |
| Run it at work, in production, at any scale | ⚠️ grey area | ✅ no permission needed |
| Modify it for your own use, without distributing it | ✅ | ✅ |
| Redistribute it, modified or not | ✅ non-commercially only | ✅ commercially too |
| Redistribute it **without handing over the source** | ✅ allowed | ❌ **the one thing now asked in return** |
| Combine it with GPL / AGPL code | ❌ no compatible licence exists | ✅ |
| Patent licence | ❌ excluded (§2(b)(2)) | ✅ granted (§11) |

**When the commercial licence is the answer instead**

| | Before — CC BY-NC-SA 4.0 | Now — AGPL-3.0-only + commercial |
|---|---|---|
| Ship it inside your product, publishing your modified source | ❌ forbidden outright | ✅ free, under the AGPL |
| Ship it inside your product, **keeping your source closed** | ❌ forbidden outright | 💼 commercial licence |
| Get a warranty, an indemnity or a support commitment | ❌ none available | 💼 commercial licence |

The short version : **using** it never requires a commercial licence, and now never requires permission either. Only **conveying** it while withholding the corresponding source does.

Copyright and attribution notices, the licence history and the third-party terms that apply to the published Docker image are recorded in [`NOTICE`][link-to-notice-file].

> **Already running a version from before the change ?** Nothing is withdrawn from you. CC BY-NC-SA 4.0 is irrevocable (§2(a)(1)), so the copies obtained under it keep those terms for good. The change only means that everything released from [#304](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/304) onwards comes under the AGPL — and as the tables above show, that grants you more than you had, at the cost of a single new obligation which never triggers unless you redistribute the program.

[agpl]: https://www.gnu.org/licenses/agpl-3.0
[agpl-shield]: https://img.shields.io/badge/License-AGPL%20v3-blue.svg
[commercial-shield]: https://img.shields.io/badge/Commercial%20licence-available-brightgreen.svg
[link-to-license-file]: ./LICENSE
[link-to-commercial-license-file]: ./LICENSE-COMMERCIAL.md
[link-to-notice-file]: ./NOTICE

<p align="right">(<a href="#top">back to top</a>)</p>
