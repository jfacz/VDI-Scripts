# Omnissa Horizon REST API Scripts

A collection of PowerShell scripts for managing Omnissa Horizon using its REST API. 

## Overview

These scripts help you automate common tasks like cloning VDI pools or pushing new images. You can run them using interactive menus or silently using parameters.
Passwords are safe. On the first run, the script asks for the API password and saves it locally encrypted (using Windows DPAPI).

## Scripts

* **HorizonAPI_Fce.ps1** - The core library file. It handles login, API requests, and menus. *Must be in the same folder as the other scripts.*
* **HorizonAPI_PoolClone.ps1** - Clones an existing Instant Clone desktop pool to create a new one. It copies all settings (Parent VM, snapshot, network).
* **HorizonAPI_PoolPushImage.ps1** - Schedules a "Push Image" task to update the golden image for one or multiple desktop pools.

## Requirements & Security

* **PowerShell 5.1+** (no extra modules needed).
* **Passwords** are securely encrypted (using Windows DPAPI) and saved in a local file into the script directory
