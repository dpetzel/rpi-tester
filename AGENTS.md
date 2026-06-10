

## Required Tests
The script should make sure to test the following:
* Device is not suffering any power/undervoltage issues
* Idle temperatures are with normal ranges
* A CPU stress test should be run for at least 60 seconds
* Memory should be tested
* Confirm the boot media is good
* Verify all USB ports are functional
* Ethernet jack is functional on models that have one
* Wifi is functional on models that have it
* Bluetooth is functional on models that have it
* HDMI is connected/working
* Confirm visual display using all HDMI ports (varies by model)
* Confirm audio over audio jack (dependent on model)
* Confirm camera is working. Even on devices that have the connector
  we may not have a camera so we give user choice of yes, no, skip


## Functional Requirements
The Raspberry PI Tester must meet the following functional requirements:

### Multi-Model Support
The testing script must be able to run on multiple
models of Raspberry PI. It must automatically detect the model and test
accordingly. A user must *not* be required to specify the model.

### Console Output
Upon conclusion of the script, the screen output should
be reset and a summary of the test results should be display. Color coding
should be used to denote things which have passed, failed, or are a warning.

### Results File
Results of the test should be output into a Markdown formatted file named
`testResults.md`

### Test Automation
Any test which does not require human intervention should be run automatically

### Manual Tests
Certain things may require a human to verify. Examples might be having a user
confirm that they visually see output on the display monitor, or can hear
audio through the audio jack. For tests like these, during the testing process
the user should be prompted to confirm. That confirmation should be stored and
included in the the results, both console and file

## Non-Functional Requirements
The script should be a single, fully self contained shell script which can
be downloaded and executed without needing to download more files from this
repo.



