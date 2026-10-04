# RMNET support for Qualcomm NSS

This module connects vendor QMAP interfaces to the Qualcomm NSS data path.
It exports the `rmnet_nss_callbacks` interface for the Quectel drivers.
It is separate from the standard Linux `rmnet` driver.

## History

The source credits The Linux Foundation (2019–2021) and Qualcomm Innovation Center (2022).
This import uses QModem commit `df51f56f707b8ac1443f48ffc1aaf7204f75c1d8`.
The C and header files match the qosmio `NSS-12.5-K6.x-wwan` branch.
The package retains QModem's `ccflags-y` build fix.

## Use

Select `kmod-rmnet-nss` in a compatible Qualcomm NSS build.
The package selects `kmod-qca-nss-drv` and its RMNET and C2C support.
It installs the callback header for driver compilation.
Load `rmnet_nss` before the vendor modem driver.

## Tests

The same module carried live PCIe modem traffic on Cudy P5 with an RM551E-GL.
The test used Quectel MHI 1.6.0, wwand, Linux 6.18.54, and NSS firmware 12.2.
NSS RMNET receive counters increased during the connection.
The relocated package still needs a build and hardware tests.

The original source notices remain unchanged. See `LICENSE` for GPL version 2.
